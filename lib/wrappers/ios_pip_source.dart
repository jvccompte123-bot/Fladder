import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/profiles/ios_pip_profile.dart';

/// A separate server playback session, released without stopping MPV's session.
class IosPipSource {
  IosPipSource(
      {required this.url, required this.isLive, required this.release});
  final String url;
  final bool isLive;
  final Future<void> Function() release;
}

class IosPipSourceException implements Exception {
  const IosPipSourceException(this.code);
  final String code;
  @override
  String toString() => code; // Never include an authenticated media URL.
}

/// Injecting the three server operations also lets tests exercise failures and
/// ownership of live-stream handles without a Jellyfin server or an iPhone.
class IosPipSourceFactory {
  IosPipSourceFactory(
      {required this.negotiate,
      required this.resolveUrl,
      required this.release});
  final Future<PlaybackInfoResponse> Function(
      String itemId, PlaybackInfoDto request) negotiate;
  final String Function(String relativeUrl) resolveUrl;
  final Future<void> Function(String sessionId, String? liveStreamId) release;

  Future<IosPipSource> prepare({
    required String itemId,
    required String userId,
    required bool isLive,
    String? mediaSourceId,
    String? existingLiveStreamId,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
    int? maxStreamingBitrate,
  }) async {
    final info = await negotiate(
        itemId,
        iosPipPlaybackRequest(
          userId: userId,
          mediaSourceId: mediaSourceId,
          liveStreamId: existingLiveStreamId,
          audioStreamIndex: audioStreamIndex,
          subtitleStreamIndex: subtitleStreamIndex,
          maxStreamingBitrate: maxStreamingBitrate,
        ));
    final sources = info.mediaSources ?? [];
    final source = sources.where((s) => s.id == mediaSourceId).firstOrNull ??
        sources.firstOrNull;
    final sessionId = info.playSessionId;
    // A returned handle may be shared with MPV; never close that handle here.
    final ownedLiveId = source?.liveStreamId != existingLiveStreamId
        ? source?.liveStreamId
        : null;
    bool released = false;
    Future<void> releaseOnce() async {
      if (released) return;
      released = true;
      if (sessionId != null && sessionId.isNotEmpty) {
        await release(sessionId, ownedLiveId);
      }
    }

    final relative = source?.transcodingUrl;
    if (sessionId == null ||
        sessionId.isEmpty ||
        source?.supportsTranscoding != true ||
        relative == null ||
        relative.isEmpty) {
      await releaseOnce();
      throw const IosPipSourceException('jellyfin_hls_unavailable');
    }
    final uri = Uri.tryParse(resolveUrl(relative));
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        !uri.path.toLowerCase().endsWith('.m3u8')) {
      await releaseOnce();
      throw const IosPipSourceException('jellyfin_invalid_hls');
    }
    return IosPipSource(
        url: uri.toString(), isLive: isLive, release: releaseOnce);
  }
}
