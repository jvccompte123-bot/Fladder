import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/models/media_playback_model.dart';
import 'package:fladder/providers/pip_provider.dart';
import 'package:fladder/providers/settings/video_player_settings_provider.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/wrappers/pip_manager.dart';

class PipLifecycleController extends ConsumerStatefulWidget {
  const PipLifecycleController({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<PipLifecycleController> createState() => _PipLifecycleControllerState();
}

class _PipLifecycleControllerState extends ConsumerState<PipLifecycleController> with WidgetsBindingObserver {
  StreamSubscription<IosPipRestoreEvent>? _iosRestoreSubscription;
  IosPipRestoreEvent? _pendingIOSRestore;
  String? _iosMediaUrl;
  StreamSubscription<bool>? _iosStateSubscription;
  Future<void> _configurationQueue = Future<void>.value();

  bool get _onIOS => !kIsWeb && Platform.isIOS;
  bool get _onAndroid => !kIsWeb && Platform.isAndroid;

  @override
  void initState() {
    super.initState();
    if (_onIOS) {
      WidgetsBinding.instance.addObserver(this);
      // Native AVPlayer owns the PiP frames on iOS. Do not configure the
      // generic PiP plugin, which would show black frames even without video.
      final manager = ref.read(pipManagerProvider);
      manager.restoreUI = () async {
        if (!mounted || ref.read(playBackModel)?.media?.url != _iosMediaUrl) return false;
        if (ref.read(mediaPlaybackProvider).state != VideoPlayerState.fullScreen) {
          unawaited(ref.read(videoPlayerProvider).openPlayer(context));
          await WidgetsBinding.instance.endOfFrame;
        }
        return mounted;
      };
      _iosStateSubscription = manager.isInPip.listen((active) {
        if (active) _iosMediaUrl = ref.read(playBackModel)?.media?.url;
      });
      _iosRestoreSubscription = ref.read(pipManagerProvider).iosRestoreEvents.listen(_restoreIOSPlayback);
    } else if (_onAndroid) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _applyCurrent());
    }
  }

  void _restoreIOSPlayback(IosPipRestoreEvent restored) {
    _pendingIOSRestore = restored;
    _applyIOSRestoreIfResumed();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _applyIOSRestoreIfResumed();
    }
  }

  Future<void> _applyIOSRestoreIfResumed() async {
    if (!mounted || WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) return;
    final restored = _pendingIOSRestore;
    if (restored == null) return;
    _pendingIOSRestore = null;
    if (_iosMediaUrl == null || ref.read(playBackModel)?.media?.url != _iosMediaUrl) return;
    // Keep the MPV player paused if the PiP user paused/closed playback.
    final player = ref.read(videoPlayerProvider);
    await player.seek(restored.position);
    if (mounted && restored.wasPlaying) {
      await player.play();
    }
  }

  void _applyCurrent() {
    if (!mounted || !_onAndroid) return;

    // Serialize configuration changes. Async native setup calls used to race
    // when playback ended or the auto-PiP switch was disabled.
    _configurationQueue = _configurationQueue.then((_) async {
      if (!mounted) return;

      final playback = ref.read(mediaPlaybackProvider);
      final model = ref.read(playBackModel);
      final enabled = ref.read(videoPlayerSettingsProvider).enablePictureInPicture;
      final isRealVideo = model?.media != null &&
          model?.isAudioPlayback == false &&
          playback.state != VideoPlayerState.disposed &&
          playback.playing &&
          !playback.completed;

      final manager = ref.read(pipManagerProvider);
      if (isRealVideo) {
        await manager.enable(aspectWidth: 16.0, aspectHeight: 9.0, autoEnter: enabled);
      } else {
        await manager.disable();
      }
    }).catchError((Object error, StackTrace stackTrace) {
      debugPrint('PiP configuration error: $error');
    });
  }

  @override
  void dispose() {
    _iosRestoreSubscription?.cancel();
    _iosStateSubscription?.cancel();
    if (_onIOS) ref.read(pipManagerProvider).restoreUI = null;
    if (_onIOS) WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!pipPlatformSupported || _onIOS) {
      return widget.child;
    }

    ref.listen<VideoPlayerState>(
      mediaPlaybackProvider.select((v) => v.state),
      (_, __) => _applyCurrent(),
    );
    ref.listen<bool>(
      mediaPlaybackProvider.select((v) => v.playing),
      (_, __) => _applyCurrent(),
    );
    ref.listen<bool>(
      mediaPlaybackProvider.select((v) => v.completed),
      (_, __) => _applyCurrent(),
    );
    ref.listen<bool>(
      videoPlayerSettingsProvider.select((v) => v.enablePictureInPicture),
      (_, __) => _applyCurrent(),
    );
    ref.listen(
      playBackModel,
      (_, __) => _applyCurrent(),
    );

    final inPip = ref.watch(pipStateProvider).asData?.value ?? false;
    final state = ref.watch(mediaPlaybackProvider.select((v) => v.state));
    if (inPip && state == VideoPlayerState.minimized) {
      final player = ref.watch(videoPlayerProvider);
      final video = player.videoWidget(const ValueKey('pip_minimized_video'), BoxFit.contain);
      final subtitle = player.subtitleWidget(false);
      return ColoredBox(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (video != null) video,
            if (subtitle != null) subtitle,
          ],
        ),
      );
    }
    return widget.child;
  }
}
