import UIKit
import AVFoundation
import AVKit
import Flutter
import workmanager_apple

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var iosPipBridge: FladderIosPip?
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    // Register with the engine, even when UIKit has not attached its window yet.
    // Resolving the source view once at launch could leave this channel absent.
    if let registrar = registrar(forPlugin: "FladderIosPip") {
      iosPipBridge = FladderIosPip(messenger: registrar.messenger()) { [weak self] in
        if let view = self?.window?.rootViewController?.view, view.window != nil {
          return view
        }
        return UIApplication.shared.connectedScenes
          .compactMap { $0 as? UIWindowScene }
          .flatMap { $0.windows }
          .first { $0.isKeyWindow }?.rootViewController?.view
      }
    }
    UNUserNotificationCenter.current().delegate = self

    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) {
      granted, error in
      if granted {
        print("Notification permission granted for debug handler")
      } else if let error = error {
        print("Error requesting notification permission: \(error)")
      }
    }

    WorkmanagerDebug.setCurrent(NotificationDebugHandler())

    WorkmanagerPlugin.registerBGProcessingTask(
      withIdentifier: "nl.jknaapen.fladder.update_notifications_check_debug")
    WorkmanagerPlugin.registerPeriodicTask(
      withIdentifier: "nl.jknaapen.fladder.update_notifications_check",
      frequency: NSNumber(value: 20 * 60))

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // Shows a notification for background tasks when the app is in the foreground
  // override func userNotificationCenter(
  //   _ center: UNUserNotificationCenter,
  //   willPresent notification: UNNotification,
  //   withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  // ) {
  //   completionHandler(.alert) 
  // }
}


// Uses a real AVPlayerLayer for iPhone Picture-in-Picture. The old generic PiP
// plugin only creates a solid black AVSampleBufferDisplayLayer and cannot show
// MPV's Flutter texture in the background.
@available(iOS 15.0, *)
final class FladderIosPip: NSObject, AVPictureInPictureControllerDelegate {
  private let channel: FlutterMethodChannel
  private let sourceViewProvider: () -> UIView?
  private weak var sourceView: UIView?
  private var player: AVPlayer?
  private var playerLayer: AVPlayerLayer?
  private var pictureController: AVPictureInPictureController?
  private var statusObservation: NSKeyValueObservation?
  private var presentationSizeObservation: NSKeyValueObservation?
  private var backgroundObserver: NSObjectProtocol?
  private var possibleObservation: NSKeyValueObservation?
  private var layerObservation: NSKeyValueObservation?
  private var seekCompleted = false
  private var seekRequested = false
  private var isLive = false
  private var initialPositionMs: Int64 = 0
  private var timeout: DispatchWorkItem?
  private var pendingStart: FlutterResult?
  private var didRequestStart = false
  private var sessionStarted = false

  init(messenger: FlutterBinaryMessenger, sourceViewProvider: @escaping () -> UIView?) {
    self.sourceViewProvider = sourceViewProvider
    channel = FlutterMethodChannel(name: "fladder/ios_pip", binaryMessenger: messenger)
    super.init()
    backgroundObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification,
      object: nil, queue: .main
    ) { [weak self] _ in
      guard let self = self, self.sessionStarted else { return }
      // Other Flutter audio plugins can change the shared audio session.
      // Reassert background playback while native PiP is already running.
      _ = self.activatePlaybackAudio()
    }
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(false)
        return
      }
      switch call.method {
      case "isSupported":
        result(AVPictureInPictureController.isPictureInPictureSupported())
      case "start":
        self.start(call.arguments, result: result)
      case "stop":
        self.stop()
        result(nil)
      case "dispose":
        self.stop()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  deinit {
    if let backgroundObserver = backgroundObserver {
      NotificationCenter.default.removeObserver(backgroundObserver)
    }
  }

  private func activatePlaybackAudio() -> Bool {
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .moviePlayback)
      try session.setActive(true)
      return true
    } catch {
      NSLog("Fladder iOS PiP: failed to activate playback audio session: %@", String(describing: error))
      return false
    }
  }

  private func updateVideoGeometry(for item: AVPlayerItem) {
    guard let view = sourceView, let layer = playerLayer else { return }

    // The encoded media may be 2.39:1, 4:3, portrait, etc.
    // Match the video instead of using the phone screen as a video frame.
    let size = item.presentationSize
    let valid = size.width > 0 && size.height > 0 &&
        size.width.isFinite && size.height.isFinite
    let aspect = valid ? size.width / size.height : 16.0 / 9.0
    let width = max(1.0, min(view.bounds.width, view.bounds.height * aspect))
    let height = width / max(0.1, aspect)
    let originY = (view.bounds.height - height) / 2.0
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.frame = CGRect(x: (view.bounds.width - width) / 2, y: originY, width: width, height: height)
    layer.videoGravity = .resizeAspect
    CATransaction.commit()
  }

  private func start(_ rawArguments: Any?, result: @escaping FlutterResult) {
    guard pendingStart == nil, !sessionStarted,
          let arguments = rawArguments as? [String: Any],
          let rawUrl = arguments["url"] as? String,
          let url = URL(string: rawUrl),
          ["https", "http", "file"].contains(url.scheme?.lowercased() ?? ""),
          let view = sourceViewProvider(), view.window != nil,
          AVPictureInPictureController.isPictureInPictureSupported() else {
      result(FlutterError(code: "ios_pip_unavailable", message: "No active video window or PiP session available.", details: nil))
      return
    }

    cleanup()
    sourceView = view
    isLive = (arguments["isLive"] as? Bool) == true
    initialPositionMs = max(0, (arguments["positionMs"] as? NSNumber)?.int64Value ?? 0)

    // This must happen before AVPictureInPictureController is created.
    // In particular, the Flutter/MPV pause command may have deactivated
    // the shared iOS audio session just before we received this request.
    guard activatePlaybackAudio() else {
      result(FlutterError(code: "ios_audio_session", message: "Audio session could not be activated.", details: nil))
      return
    }

    let item = AVPlayerItem(url: url)
    let videoPlayer = AVPlayer(playerItem: item)
    videoPlayer.automaticallyWaitsToMinimizeStalling = true
    videoPlayer.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible

    // PiP needs an actual player layer attached to the visible app window.
    let layer = AVPlayerLayer(player: videoPlayer)
    layer.frame = CGRect(
      x: 0, y: (view.bounds.height - view.bounds.width * 9.0 / 16.0) / 2.0,
      width: view.bounds.width, height: view.bounds.width * 9.0 / 16.0
    )
    layer.videoGravity = .resizeAspect
    view.layer.addSublayer(layer)

    guard let pip = AVPictureInPictureController(playerLayer: layer) else {
      layer.removeFromSuperlayer()
      result(FlutterError(code: "ios_pip_controller", message: "AVKit could not create a PiP controller.", details: nil))
      return
    }

    pip.delegate = self
    pip.canStartPictureInPictureAutomaticallyFromInline = false
    player = videoPlayer
    playerLayer = layer
    pictureController = pip
    updateVideoGeometry(for: item)
    pendingStart = result
    didRequestStart = false

    statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] current, _ in
      DispatchQueue.main.async {
        guard let self = self, self.player?.currentItem === current else { return }
        if current.status == .failed {
          self.failStart(self.failureCode("ios_media", current.error))
        } else if current.status == .readyToPlay {
          self.updateVideoGeometry(for: current)
          self.preparePlayback(current)
        }
      }
    }
    presentationSizeObservation = item.observe(\.presentationSize, options: [.initial, .new]) { [weak self] current, _ in
      DispatchQueue.main.async {
        guard let self = self, self.player?.currentItem === current else { return }
        self.updateVideoGeometry(for: current)
      }
    }
    possibleObservation = pip.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] current, _ in
      DispatchQueue.main.async {
        guard let self = self, self.pictureController === current else { return }
        self.tryStart()
      }
    }

    layerObservation = layer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] current, _ in
      DispatchQueue.main.async {
        guard let self = self, self.playerLayer === current else { return }
        self.tryStart()
      }
    }

    // Prevent an unsupported codec, unreachable NAS or a failed AVKit session
    // from leaving the normal MPV player paused forever.
    let work = DispatchWorkItem { [weak self] in
      if self?.pendingStart != nil { self?.failStart("ios_pip_timeout") }
    }
    timeout = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
  }

  private func preparePlayback(_ item: AVPlayerItem) {
    guard pendingStart != nil, !seekRequested, let videoPlayer = player else { return }
    seekRequested = true
    // Live TV is not a movie timeline. Seeking to an EPG time (or zero) can
    // fail or wait forever, preventing AVKit from receiving its first frame.
    if isLive || initialPositionMs == 0 {
      seekCompleted = true
      videoPlayer.play()
      tryStart()
      return
    }
    let time = CMTime(value: initialPositionMs, timescale: 1000)
    videoPlayer.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
      DispatchQueue.main.async {
        guard let self = self, self.player === videoPlayer, self.pendingStart != nil else { return }
        guard finished else { self.failStart("ios_seek_failed"); return }
        self.seekCompleted = true
        videoPlayer.play()
        self.tryStart()
      }
    }
  }

  private func failureCode(_ stage: String, _ error: Error?) -> String {
    guard let error = error as NSError? else { return stage }
    // Domains and numeric codes are safe to share; localizedDescription and
    // userInfo can contain the server URL and authentication query string.
    return "\(stage)_\(error.domain)_\(error.code)"
  }

  private func tryStart() {
    guard pendingStart != nil, !didRequestStart, seekCompleted,
          playerLayer?.isReadyForDisplay == true,
          pictureController?.isPictureInPicturePossible == true,
          player?.currentItem?.status == .readyToPlay else { return }
    // The MPV player pauses its shared audio session on transfer.
    // Make sure native AVPlayer owns an active session before requesting PiP.
    guard activatePlaybackAudio() else {
      failStart("ios_audio_session")
      return
    }
    didRequestStart = true
    pictureController?.startPictureInPicture()
  }

  private func failStart(_ code: String = "ios_pip_cancelled") {
    guard let result = pendingStart else { return }
    pendingStart = nil
    cleanup()
    emit("failed")
    result(FlutterError(code: code, message: "Native PiP could not start.", details: nil))
  }

  private func stop() {
    if pictureController?.isPictureInPictureActive == true {
      pictureController?.stopPictureInPicture()
    } else if pendingStart != nil {
      failStart()
    } else {
      cleanup()
    }
  }

  private func cleanup() {
    timeout?.cancel()
    timeout = nil
    layerObservation = nil
    seekCompleted = false
    seekRequested = false
    possibleObservation = nil
    statusObservation = nil
    presentationSizeObservation = nil
    pictureController?.delegate = nil
    pictureController = nil
    player?.pause()
    player?.replaceCurrentItem(with: nil)
    player = nil
    playerLayer?.removeFromSuperlayer()
    playerLayer = nil
    didRequestStart = false
    sessionStarted = false
  }

  private func emit(_ status: String, extra: [String: Any] = [:]) {
    var data = extra
    data["status"] = status
    channel.invokeMethod("state", arguments: data)
  }

  func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
    guard controller === pictureController else { return }
    sessionStarted = true
    _ = activatePlaybackAudio()
    timeout?.cancel()
    timeout = nil
    let result = pendingStart
    pendingStart = nil
    // AVKit owns presentation while PiP is active. Keep the source layer
    // attached without changing its visibility or stacking during transition.
    NSLog("Fladder PiP: didStart")
    emit("started")
    result?(true)
  }

  func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    guard controller === pictureController else { return }
    let failure = error as NSError
    NSLog("Fladder PiP: start failed domain=%@ code=%ld", failure.domain, failure.code)
    failStart(failureCode("ios_avkit", error))
  }

  func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
    guard controller === pictureController else { return }
    let seconds = player?.currentTime().seconds ?? 0
    let safeSeconds = seconds.isFinite ? max(0, seconds) : 0
    let positionMs = Int64(safeSeconds * 1000)
    let playing = (player?.rate ?? 0) > 0
    emit("stopped", extra: ["positionMs": positionMs, "playing": playing])
    cleanup()
  }

  func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
  ) {
    channel.invokeMethod("restoreUI", arguments: nil) { result in
      completionHandler((result as? Bool) == true)
    }
  }
}
