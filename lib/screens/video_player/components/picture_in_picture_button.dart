import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax_plus/iconsax_plus.dart';

import 'package:fladder/providers/ios_pip_playback_provider.dart';
import 'package:fladder/providers/pip_provider.dart';
import 'package:fladder/util/localization_helper.dart';
import 'package:fladder/wrappers/ios_pip_source.dart';
import 'package:fladder/wrappers/pip_manager.dart';

/// The same real PiP entry point for movies, TV controls and the TV guide.
class PictureInPictureButton extends ConsumerStatefulWidget {
  const PictureInPictureButton({super.key, required this.onStarted});
  final VoidCallback onStarted;

  @override
  ConsumerState<PictureInPictureButton> createState() =>
      _PictureInPictureButtonState();
}

class _PictureInPictureButtonState
    extends ConsumerState<PictureInPictureButton> {
  bool _starting = false;

  Future<void> _start() async {
    setState(() => _starting = true);
    final isIOS = !kIsWeb && Platform.isIOS;
    String failure = 'pip_not_started';
    bool started = false;
    try {
      started = isIOS
          ? await ref.read(iosPipPlaybackProvider).start()
          : await ref.read(pipManagerProvider).enter();
    } on IosPipSourceException catch (error) {
      failure = error.code;
    } on PlatformException catch (error) {
      // Native codes contain no URLs, tokens or server response bodies.
      failure = error.code;
    } on MissingPluginException {
      failure = 'ios_bridge_missing';
    } catch (_) {
      failure = 'pip_connection_failed';
    } finally {
      if (mounted) setState(() => _starting = false);
    }
    if (!mounted) return;
    if (started) {
      // Only leave the inline player after AVKit's didStart callback.
      if (isIOS) widget.onStarted();
      return;
    }
    if (!isIOS) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.localized.pictureInPictureNotSupported)),
      );
      return;
    }
    final french = Localizations.localeOf(context).languageCode == 'fr';
    await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
              title: const Text('Picture-in-Picture'),
              content: SelectableText(french
                  ? 'Le PiP n’a pas pu démarrer. La lecture normale reste disponible.\n\n'
                      'Code : $failure\nVersion PiP : HLS-2\n\n'
                      'Le PiP utilise un flux compatible Apple fourni par Jellyfin. '
                      'Le serveur doit autoriser la conversion vidéo et audio. '
                      'Si le problème persiste, transmettez ce code.'
                  : 'PiP could not start. Normal playback remains available.\n\n'
                      'Code: $failure\nPiP version: HLS-2\n\n'
                      'PiP uses an Apple-compatible Jellyfin stream. The server must allow '
                      'video and audio transcoding. Please report this code if the problem persists.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    child: Text(context.localized.close))
              ],
            ));
  }

  @override
  Widget build(BuildContext context) {
    if (!pipPlatformSupported) return const SizedBox.shrink();
    if (!Platform.isIOS &&
        MediaQuery.orientationOf(context) != Orientation.landscape) {
      return const SizedBox.shrink();
    }
    if (!Platform.isIOS) {
      return IconButton(
        tooltip: context.localized.pictureInPictureTitle,
        onPressed: _starting ? null : _start,
        icon: const Icon(IconsaxPlusLinear.screenmirroring),
      );
    }
    // Keep the same 48 px footprint as the other player controls in portrait.
    return IconButton(
      key: const ValueKey('native_pip_button'),
      tooltip: context.localized.pictureInPictureTitle,
      iconSize: 32,
      onPressed: _starting ? null : _start,
      icon: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _starting
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.picture_in_picture_alt, size: 20),
          const Text('PiP',
              textScaler: TextScaler.noScaling,
              style: TextStyle(fontSize: 10, height: 1)),
        ],
      ),
    );
  }
}
