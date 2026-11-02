import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fladder/models/playback/offline_playback_model.dart';
import 'package:fladder/models/media_playback_model.dart';
import 'package:fladder/wrappers/pip_manager.dart';
import 'package:fladder/models/playback/tv_playback_model.dart';
import 'package:fladder/providers/api_provider.dart';
import 'package:fladder/providers/connectivity_provider.dart';
import 'package:fladder/providers/settings/video_player_settings_provider.dart';
import 'package:fladder/util/bitrate_helper.dart';
import 'package:fladder/providers/pip_provider.dart';
import 'package:fladder/providers/user_provider.dart';
import 'package:fladder/providers/video_player_provider.dart';
import 'package:fladder/wrappers/ios_pip_source.dart';

final iosPipPlaybackProvider = Provider((ref) => IosPipPlayback(ref));

class IosPipPlayback {
  IosPipPlayback(this.ref);
  final Ref ref;
  bool _preparing = false;

  Future<bool> start() async {
    if (_preparing || iosNativePipActive) return false;
    _preparing = true;
    IosPipSource? source;
    StreamSubscription<bool>? ended;
    bool started = false;
    try {
      final manager = ref.read(pipManagerProvider);
      if (!await manager.isSupported()) {
        throw const IosPipSourceException('ios_pip_unavailable');
      }
      final model = ref.read(playBackModel);
      final playback = ref.read(mediaPlaybackProvider);
      final player = ref.read(videoPlayerProvider);
      if (model?.media == null || model!.isAudioPlayback || !playback.playing) {
        return false;
      }
      final originalUrl = model.media!.url;
      final isLive = model is TvPlaybackModel;
      if (model is OfflinePlaybackModel) {
        source = IosPipSource(
          url: Uri.file(originalUrl).toString(),
          isLive: false,
          release: () async {},
        );
      } else {
        final account = ref.read(userProvider);
        if (account == null) {
          throw const IosPipSourceException('jellyfin_account_missing');
        }
        final api = ref.read(jellyApiProvider);
        final mediaSource = model.playbackInfo?.mediaSources
                ?.where(
                    (s) => s.id == model.mediaStreams?.currentVersionStream?.id)
                .firstOrNull ??
            model.playbackInfo?.mediaSources?.firstOrNull;
        final factory = IosPipSourceFactory(
          negotiate: (id, request) async {
            final response = await api.itemsItemIdPlaybackInfoPost(
                itemId: id, body: request);
            if (!response.isSuccessful || response.body == null) {
              throw IosPipSourceException(
                  'jellyfin_http_${response.statusCode}');
            }
            return response.body!;
          },
          resolveUrl: (url) => buildServerUrl(ref, relativeUrl: url),
          release: (sessionId, liveStreamId) async {
            // Never issue an unscoped DELETE, which would kill MPV as well.
            try {
              await api.api.videosActiveEncodingsDelete(
                deviceId: account.credentials.deviceId,
                playSessionId: sessionId,
              );
            } finally {
              if (liveStreamId != null) {
                await api.api.liveStreamsClosePost(liveStreamId: liveStreamId);
              }
            }
          },
        );
        final settings = ref.read(videoPlayerSettingsProvider);
        final bitrate = selectPlaybackBitrate(
          homeInternet: ref.read(connectivityStatusProvider).homeInternet,
          maxHomeBitrate: settings.maxHomeBitrate,
          maxInternetBitrate: settings.maxInternetBitrate,
        ).bitRate;
        source = await factory.prepare(
          maxStreamingBitrate: bitrate != null && bitrate > 0 ? bitrate : null,
          itemId: model is TvPlaybackModel ? model.channel.id : model.item.id,
          userId: account.id,
          isLive: isLive,
          mediaSourceId: mediaSource?.id,
          existingLiveStreamId: mediaSource?.liveStreamId,
          audioStreamIndex: model.mediaStreams?.defaultAudioStreamIndex ??
              mediaSource?.defaultAudioStreamIndex,
          subtitleStreamIndex: model.mediaStreams?.defaultSubStreamIndex ??
              mediaSource?.defaultSubtitleStreamIndex,
        );
      }
      // Preparing a transcode must not interrupt a newly selected title.
      if (ref.read(playBackModel)?.media?.url != originalUrl ||
          ref.read(mediaPlaybackProvider).state == VideoPlayerState.disposed) {
        return false;
      }
      final prepared = source;
      ended = manager.isInPip.listen((active) {
        if (!active) {
          unawaited(prepared.release().catchError((Object _) {}));
          unawaited(ended?.cancel());
        }
      });
      started = await manager.enterIOSPlayback(
        mediaUrl: source.url,
        position:
            isLive ? Duration.zero : ref.read(mediaPlaybackProvider).position,
        isLive: isLive,
        pause: () async {
          await player.pause();
          if (ref.read(playBackModel)?.media?.url != originalUrl ||
              ref.read(mediaPlaybackProvider).state ==
                  VideoPlayerState.disposed) {
            throw const IosPipSourceException('pip_playback_changed');
          }
        },
        resume: () async {
          if (ref.read(playBackModel)?.media?.url == originalUrl &&
              ref.read(mediaPlaybackProvider).state !=
                  VideoPlayerState.disposed) {
            await player.play();
          }
        },
      );
      return started;
    } finally {
      if (!started) {
        await ended?.cancel();
        try {
          await source?.release();
        } catch (_) {/* Preserve the original start failure. */}
      }
      _preparing = false;
    }
  }
}
