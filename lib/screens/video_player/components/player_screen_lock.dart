import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:fladder/util/localization_helper.dart';

/// Owns the orientation preference for the lifetime of a fullscreen player.
/// The barrier surrounds all gestures, including pinch and next-episode UI.
class PlayerScreenLock extends StatefulWidget {
  const PlayerScreenLock({super.key, required this.child, required this.allowedOrientations});

  final Widget child;
  final List<DeviceOrientation> allowedOrientations;

  @override
  State<PlayerScreenLock> createState() => _PlayerScreenLockState();
}

class _PlayerScreenLockState extends State<PlayerScreenLock> {
  static const _channel = MethodChannel('fladder/player_orientation');
  bool _locked = false;
  bool _busy = false;
  Future<void> _orientationUpdates = Future<void>.value();

  List<DeviceOrientation> get _allowed =>
      widget.allowedOrientations.isEmpty ? DeviceOrientation.values : widget.allowedOrientations;

  Future<void> _orient(List<DeviceOrientation> orientations) {
    final update = _orientationUpdates.then((_) => SystemChrome.setPreferredOrientations(orientations));
    // A failed platform request must not prevent a later unlock or cleanup.
    _orientationUpdates = update.catchError((Object _) {});
    return update;
  }

  @override
  void initState() {
    super.initState();
    unawaited(_orient(_allowed).catchError((Object _) {}));
  }

  @override
  void didUpdateWidget(PlayerScreenLock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_locked && !_busy && !listEquals(oldWidget.allowedOrientations, widget.allowedOrientations)) {
      unawaited(_orient(_allowed).catchError((Object _) {}));
    }
  }

  Future<void> _lock() async {
    if (_busy || _locked) return;
    setState(() => _busy = true);
    try {
      // Read the displayed UIKit orientation, not the physical device sensor.
      // Both landscape directions must remain distinct, even when lying down.
      final name = await _channel.invokeMethod<String>('currentOrientation');
      final orientation = DeviceOrientation.values.singleWhere((value) => value.toString() == name);
      if (!mounted) return;
      await _orient([orientation]);
      if (!mounted) return;
      setState(() => _locked = true);
      _showUnlockHint();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(context.localized.playerScreenLockFailed)),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _unlock() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _orient(_allowed);
      if (mounted) setState(() => _locked = false);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(context.localized.playerScreenLockFailed)),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showUnlockHint() {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(context.localized.playerScreenUnlockHint), duration: const Duration(seconds: 2)),
    );
  }

  @override
  void dispose() {
    // Queue cleanup after any in-flight lock so it cannot re-lock the library.
    unawaited(_orient(DeviceOrientation.values).catchError((Object _) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PlayerScreenLockScope(
        locked: _locked,
        busy: _busy,
        lock: _lock,
        child: PopScope(
          canPop: !_locked,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ExcludeFocus(
                excluding: _locked,
                child: ExcludeSemantics(
                  excluding: _locked,
                  child: AbsorbPointer(absorbing: _locked, child: widget.child),
                ),
              ),
              if (_locked)
                SafeArea(
                  minimum: const EdgeInsets.all(16),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Semantics(
                      label: context.localized.playerScreenUnlockHint,
                      button: true,
                      onLongPress: _busy ? null : _unlock,
                      child: Material(
                        color: Colors.black54,
                        shape: const CircleBorder(),
                        child: InkWell(
                          key: const ValueKey('player_screen_unlock'),
                          customBorder: const CircleBorder(),
                          onTap: _showUnlockHint,
                          onLongPress: _busy ? null : _unlock,
                          child: const Padding(
                            padding: EdgeInsets.all(16),
                            child: Icon(Icons.lock_outline, color: Colors.white),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
}

class PlayerScreenLockScope extends InheritedWidget {
  const PlayerScreenLockScope(
      {super.key, required super.child, required this.locked, required this.busy, required this.lock});
  final bool locked;
  final bool busy;
  final VoidCallback lock;

  static PlayerScreenLockScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PlayerScreenLockScope>();

  @override
  bool updateShouldNotify(PlayerScreenLockScope oldWidget) => locked != oldWidget.locked || busy != oldWidget.busy;
}

class PlayerScreenLockButton extends StatelessWidget {
  const PlayerScreenLockButton({super.key});

  @override
  Widget build(BuildContext context) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return const SizedBox.shrink();
    final scope = PlayerScreenLockScope.maybeOf(context);
    if (scope == null) return const SizedBox.shrink();
    return IconButton(
      key: const ValueKey('player_screen_lock'),
      tooltip: context.localized.playerScreenLock,
      onPressed: scope.busy ? null : scope.lock,
      icon: const Icon(Icons.lock_open_outlined),
    );
  }
}
