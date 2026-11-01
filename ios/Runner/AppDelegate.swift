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
    if let controller = window?.rootViewController as? FlutterViewController {
      iosPipBridge = FladderIosPip(messenger: controller.binaryMessenger,
                                   sourceView: controller.view)
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
  private weak var sourceView: UIView?
  private var player: AVPlayer?
  private var playerLayer: AVPlayerLayer?
  private var pictureController: AVPictureInPictureController?
  private var statusObservation: NSKeyValueObservation?
  private var presentationSizeObservation: NSKeyValueObservation?
  private var backgroundObserver: NSObjectProtocol?
  private var possibleObservation: NSKeyValueObservation?
  private var timeout: DispatchWorkItem?
  private var pendingStart: FlutterResult?
  private var didRequestStart = false
  private var sessionStarted = false

  init(messenger: FlutterBinaryMessenger, sourceView: UIView) {
    self.sourceView = sourceView
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
    let width = max(1.0, view.bounds.width)
    let height = width / max(0.1, aspect)
    let originY = (view.bounds.height - height) / 2.0
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.frame = CGRect(x: 0, y: originY, width: width, height: height)
    layer.videoGravity = .resizeAspect
    CATransaction.commit()
  }

  private func start(_ rawArguments: Any?, result: @escaping FlutterResult) {
    guard pendingStart == nil, !sessionStarted,
          let arguments = rawArguments as? [String: Any],
          let rawUrl = arguments["url"] as? String,
          let url = URL(string: rawUrl),
          ["https", "http", "file"].contains(url.scheme?.lowercased() ?? ""),
          let view = sourceView, view.window != nil,
          AVPictureInPictureController.isPictureInPictureSupported() else {
      result(false)
      return
    }

    cleanup()

    // This must happen before AVPictureInPictureController is created.
    // In particular, the Flutter/MPV pause command may have deactivated
    // the shared iOS audio session just before we received this request.
    guard activatePlaybackAudio() else {
      result(false)
      return
    }

    let item = AVPlayerItem(url: url)
    let videoPlayer = AVPlayer(playerItem: item)
    videoPlayer.automaticallyWaitsToMinimizeStalling = true

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
      result(false)
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
        guard let self = self, self.pendingStart != nil else { return }
        if current.status == .failed {
          self.failStart()
        } else if current.status == .readyToPlay {
          self.updateVideoGeometry(for: current)
          self.tryStart()
        }
      }
    }
    presentationSizeObservation = item.observe(\.presentationSize, options: [.initial, .new]) { [weak self] current, _ in
      DispatchQueue.main.async { self?.updateVideoGeometry(for: current) }
    }
    possibleObservation = pip.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] _, _ in
      DispatchQueue.main.async { self?.tryStart() }
    }

    let positionMs = max(0, (arguments["positionMs"] as? NSNumber)?.int64Value ?? 0)
    let time = CMTime(value: positionMs, timescale: 1000)
    videoPlayer.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
      DispatchQueue.main.async {
        guard let self = self, self.pendingStart != nil else { return }
        self.player?.play()
        self.tryStart()
      }
    }

    // Prevent an unsupported codec, unreachable NAS or a failed AVKit session
    // from leaving the normal MPV player paused forever.
    let work = DispatchWorkItem { [weak self] in
      if self?.pendingStart != nil { self?.failStart() }
    }
    timeout = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
  }

  private func tryStart() {
    guard pendingStart != nil, !didRequestStart,
          pictureController?.isPictureInPicturePossible == true,
          player?.currentItem?.status == .readyToPlay else { return }
    // The MPV player pauses its shared audio session on transfer.
    // Make sure native AVPlayer owns an active session before requesting PiP.
    guard activatePlaybackAudio() else {
      failStart()
      return
    }
    didRequestStart = true
    pictureController?.startPictureInPicture()
  }

  private func failStart() {
    guard let result = pendingStart else { return }
    pendingStart = nil
    result(false)
    emit("failed")
    cleanup()
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
    sessionStarted = true
    _ = activatePlaybackAudio()
    timeout?.cancel()
    timeout = nil
    let result = pendingStart
    pendingStart = nil
    // AVKit renders the PiP window from the player, not this inline layer.
    playerLayer?.opacity = 0
    emit("started")
    result?(true)
  }

  func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    failStart()
  }

  func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
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
    completionHandler(true)
  }
}
