import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:pip/pip.dart';

// MPV must not deactivate the app-wide audio session while native iOS PiP
// is playing. The Flutter audio session is shared with AVPlayer.
bool iosNativePipActive = false;

bool get pipPlatformSupported {
  if (kIsWeb) return false;
  return Platform.isAndroid || Platform.isIOS;
}

abstract class PipClient {
  Future<bool> isSupported();
  Future<bool> isAutoEnterSupported();
  Future<void> setup({
    required double aspectWidth,
    required double aspectHeight,
    required bool autoEnterEnabled,
  });

  // stop() only exits an active session; this re-runs setup with auto-enter off.
  Future<void> disableAutoEnter();
  Future<bool> start();
  Future<void> stop();
  void registerStateChangedObserver(void Function(bool isInPip) observer);
  Future<void> dispose();
}

class _RealPipClient implements PipClient {
  _RealPipClient() : _pip = Pip();

  final Pip _pip;
  bool _observerRegistered = false;

  @override
  Future<bool> isSupported() async {
    if (!pipPlatformSupported) return false;
    return _pip.isSupported();
  }

  @override
  Future<bool> isAutoEnterSupported() => _pip.isAutoEnterSupported();

  @override
  Future<void> setup({
    required double aspectWidth,
    required double aspectHeight,
    required bool autoEnterEnabled,
  }) async {
    await _pip.setup(PipOptions(
      autoEnterEnabled: autoEnterEnabled,
      aspectRatioX: aspectWidth.toInt(),
      aspectRatioY: aspectHeight.toInt(),
    ));
  }

  @override
  Future<void> disableAutoEnter() async {
    await _pip.setup(const PipOptions(autoEnterEnabled: false));
  }

  @override
  Future<bool> start() => _pip.start();

  @override
  Future<void> stop() => _pip.stop();

  @override
  void registerStateChangedObserver(void Function(bool isInPip) observer) {
    final wrapped = PipStateChangedObserver(
      onPipStateChanged: (state, error) {
        observer(state == PipState.pipStateStarted);
      },
    );
    _pip.registerStateChangedObserver(wrapped);
    _observerRegistered = true;
  }

  @override
  Future<void> dispose() async {
    if (_observerRegistered) {
      await _pip.unregisterStateChangedObserver();
      _observerRegistered = false;
    }
    await _pip.dispose();
  }
}

/// Position and playback state when iOS gives control back to Fladder.
class IosPipRestoreEvent {
  const IosPipRestoreEvent(this.position, this.wasPlaying);

  final Duration position;
  final bool wasPlaying;
}

/// Unlike the generic PiP plugin, this implementation supplies real AVPlayer
/// video frames to AVKit. The native player only starts on explicit user action.
class IosPipClient implements PipClient {
  static const _channel = MethodChannel('fladder/ios_pip');

  void Function(bool)? _observer;
  void Function(IosPipRestoreEvent)? onRestore;
  bool _hasStarted = false;
  bool _starting = false;
  bool suppressRestore = false;
  Completer<void>? _stopping;
  Future<bool> Function()? restoreUI;

  @override
  Future<bool> isSupported() async => await _channel.invokeMethod<bool>('isSupported') ?? false;

  @override
  Future<bool> isAutoEnterSupported() async => false;

  @override
  Future<void> setup({
    required double aspectWidth,
    required double aspectHeight,
    required bool autoEnterEnabled,
  }) async {
    // iOS: never set up auto-enter without a valid video source.
  }

  @override
  Future<void> disableAutoEnter() async {}

  @override
  Future<bool> start() async => false;

  Future<bool> startWithMedia(String url, Duration position) async {
    if (_starting || _hasStarted) return false;
    _starting = true;
    try {
      return await _channel.invokeMethod<bool>('start', {
        'url': url,
        'positionMs': position.inMilliseconds,
      }) ?? false;
    } finally {
      _starting = false;
    }
  }

  @override
  Future<void> stop() async {
    if (!_hasStarted) {
      await _channel.invokeMethod<void>('stop');
      return;
    }
    final completion = _stopping ??= Completer<void>();
    await _channel.invokeMethod<void>('stop');
    await completion.future;
  }

  @override
  void registerStateChangedObserver(void Function(bool isInPip) observer) {
    _observer = observer;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'restoreUI') return await restoreUI?.call() ?? false;
      if (call.method != 'state') return null;
      final data = Map<String, dynamic>.from(call.arguments as Map);
      switch (data['status']) {
        case 'started':
          _hasStarted = true;
          iosNativePipActive = true;
          _observer?.call(true);
          break;
        case 'stopped':
          iosNativePipActive = false;
          _observer?.call(false);
          _stopping?.complete();
          _stopping = null;
          if (_hasStarted && !suppressRestore) {
            _hasStarted = false;
            onRestore?.call(IosPipRestoreEvent(
              Duration(milliseconds: (data['positionMs'] as num?)?.toInt() ?? 0),
              data['playing'] == true,
            ));
          }
          _hasStarted = false;
          break;
        case 'failed':
          iosNativePipActive = false;
          _observer?.call(false);
          break;
      }
    });
  }

  @override
  Future<void> dispose() async {
    iosNativePipActive = false;
    _channel.setMethodCallHandler(null);
    await _channel.invokeMethod<void>('dispose');
  }
}

// Only Android uses package:pip; iOS uses a real native AVPlayer/AVKit bridge.
class PipManager {
  PipManager({PipClient? client}) : _client = client ?? (!kIsWeb && Platform.isIOS ? IosPipClient() : _RealPipClient()) {
    _client.registerStateChangedObserver(_onStateChanged);
    if (_client is IosPipClient) {
      (_client as IosPipClient).onRestore = _restoreController.add;
      (_client as IosPipClient).restoreUI = () async => await restoreUI?.call() ?? false;
    }
  }

  Future<bool> Function()? restoreUI;

  Future<void> stopForNewPlayback() async {
    final client = _client;
    if (client is! IosPipClient) return;
    client.suppressRestore = true;
    try {
      await client.stop();
    } finally {
      client.suppressRestore = false;
    }
  }

  final PipClient _client;
  final StreamController<bool> _stateController = StreamController<bool>.broadcast();
  final StreamController<IosPipRestoreEvent> _restoreController = StreamController<IosPipRestoreEvent>.broadcast();

  Stream<IosPipRestoreEvent> get iosRestoreEvents => _restoreController.stream;

  bool _supportCached = false;
  bool _supportChecked = false;

  Stream<bool> get isInPip => _stateController.stream;

  // Always sets up aspect so manual enter() works; autoEnter gates the
  // OS auto-enter-on-background behavior independently.
  Future<bool> enable({
    required double aspectWidth,
    required double aspectHeight,
    required bool autoEnter,
  }) async {
    if (!await _ensureSupported()) return false;
    final autoEnterAllowed = autoEnter && await _client.isAutoEnterSupported();
    await _client.setup(
      aspectWidth: aspectWidth,
      aspectHeight: aspectHeight,
      autoEnterEnabled: autoEnterAllowed,
    );
    return true;
  }

  Future<void> disable() async {
    if (!await _ensureSupported()) return;
    await _client.disableAutoEnter();
    await _client.stop();
  }

  Future<bool> enter({String? mediaUrl, Duration position = Duration.zero}) async {
    if (!await _ensureSupported()) return false;
    if (_client is IosPipClient) {
      if (mediaUrl == null || mediaUrl.isEmpty) return false;
      return (_client as IosPipClient).startWithMedia(mediaUrl, position);
    }
    return _client.start();
  }

  /// Reserve the shared iOS audio session before pausing MPV. Only one
  /// transfer may run, including the period before AVKit reports "started".
  Future<bool> enterIOSPlayback({
    required String mediaUrl,
    required Duration position,
    required Future<void> Function() pause,
    required Future<void> Function() resume,
  }) async {
    if (iosNativePipActive || _client is! IosPipClient) return false;
    iosNativePipActive = true;
    bool started = false;
    try {
      await pause();
      started = await enter(mediaUrl: mediaUrl, position: position);
      return started;
    } finally {
      if (!started) {
        iosNativePipActive = false;
        await resume();
      }
    }
  }

  Future<void> dispose() async {
    await _client.dispose();
    await _stateController.close();
    await _restoreController.close();
  }

  Future<bool> _ensureSupported() async {
    if (_supportChecked) return _supportCached;
    _supportCached = await _client.isSupported();
    _supportChecked = true;
    return _supportCached;
  }

  void _onStateChanged(bool isInPip) {
    if (!_stateController.isClosed) {
      _stateController.add(isInPip);
    }
  }
}
