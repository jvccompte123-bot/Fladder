import 'package:flutter_test/flutter_test.dart';
import 'package:fladder/jellyfin/jellyfin_open_api.swagger.dart';
import 'package:fladder/wrappers/ios_pip_source.dart';

void main() {
  late List<(String, PlaybackInfoDto)> requests;
  late List<(String, String?)> releases;
  late PlaybackInfoResponse response;
  late IosPipSourceFactory factory;
  setUp(() {
    requests = [];
    releases = [];
    response =
        const PlaybackInfoResponse(playSessionId: 'pip-session', mediaSources: [
      MediaSourceInfo(
          id: 'version-2',
          path: '/movie.mkv',
          supportsTranscoding: true,
          transcodingUrl:
              '/Videos/movie/master.m3u8?PlaySessionId=pip-session'),
    ]);
    factory = IosPipSourceFactory(
      negotiate: (item, request) async {
        requests.add((item, request));
        return response;
      },
      resolveUrl: (url) => 'https://nas.invalid/jellyfin$url',
      release: (id, liveId) async {
        releases.add((id, liveId));
      },
    );
  });

  test(
      'movie negotiates HLS with the selected version and tracks, not the MPV URL',
      () async {
    final source = await factory.prepare(
        itemId: 'movie',
        userId: 'user',
        isLive: false,
        mediaSourceId: 'version-2',
        audioStreamIndex: 3,
        subtitleStreamIndex: 6);
    final (id, request) = requests.single;
    expect(id, 'movie');
    expect(request.mediaSourceId, 'version-2');
    expect(request.enableDirectPlay, isFalse);
    expect(request.enableDirectStream, isFalse);
    expect(request.audioStreamIndex, 3);
    expect(request.subtitleStreamIndex, 6);
    expect(request.alwaysBurnInSubtitleWhenTranscoding, isTrue);
    expect(request.startTimeTicks,
        0); // seek is performed on the VOD playlist timeline
    expect(
        request.deviceProfile!.transcodingProfiles!.single.videoCodec, 'h264');
    expect(
        request.deviceProfile!.transcodingProfiles!.single.audioCodec, 'aac');
    expect(source.url,
        startsWith('https://nas.invalid/jellyfin/Videos/movie/master.m3u8'));
    expect(source.isLive, isFalse);
    await source.release();
    await source.release();
    expect(releases, [('pip-session', null)]);
  });

  test(
      'live TV reuses the tuner handle without closing MPV’s handle on release',
      () async {
    response =
        const PlaybackInfoResponse(playSessionId: 'tv-pip', mediaSources: [
      MediaSourceInfo(
          id: 'tv-source',
          liveStreamId: 'shared-tuner',
          supportsTranscoding: true,
          transcodingUrl: '/Videos/channel/master.m3u8'),
    ]);
    final source = await factory.prepare(
        itemId: 'channel-id',
        userId: 'user',
        isLive: true,
        existingLiveStreamId: 'shared-tuner');
    expect(requests.single.$1, 'channel-id');
    expect(requests.single.$2.liveStreamId, 'shared-tuner');
    expect(source.isLive, isTrue);
    await source.release();
    expect(releases, [('tv-pip', null)]);
  });

  test('a newly opened live handle belongs to the PiP session and is released',
      () async {
    response =
        const PlaybackInfoResponse(playSessionId: 'tv-pip', mediaSources: [
      MediaSourceInfo(
          id: 'tv-source',
          liveStreamId: 'pip-tuner',
          supportsTranscoding: true,
          transcodingUrl: '/Videos/channel/master.m3u8'),
    ]);
    final source = await factory.prepare(
        itemId: 'channel-id', userId: 'user', isLive: true);
    await source.release();
    expect(releases, [('tv-pip', 'pip-tuner')]);
  });

  test('a server refusing HLS produces a useful failure and cleans its session',
      () async {
    response =
        const PlaybackInfoResponse(playSessionId: 'denied', mediaSources: [
      MediaSourceInfo(
          id: 'movie', supportsTranscoding: false, path: '/movie.mkv'),
    ]);
    await expectLater(
        factory.prepare(itemId: 'movie', userId: 'user', isLive: false),
        throwsA(isA<IosPipSourceException>()
            .having((e) => e.code, 'code', 'jellyfin_hls_unavailable')));
    expect(releases, [('denied', null)]);
  });

  test(
      'an invalid stream is not sent to AVPlayer and errors expose no credentials',
      () async {
    response =
        const PlaybackInfoResponse(playSessionId: 'invalid', mediaSources: [
      MediaSourceInfo(
          supportsTranscoding: true,
          transcodingUrl: '/movie.mkv?api_key=private'),
    ]);
    await expectLater(
        factory.prepare(itemId: 'movie', userId: 'user', isLive: false),
        throwsA(isA<IosPipSourceException>()
            .having((e) => e.toString(), 'message', 'jellyfin_invalid_hls')));
    expect(releases, [('invalid', null)]);
  });

  test('missing session id never issues an unscoped stop-encoding request',
      () async {
    response = const PlaybackInfoResponse(mediaSources: [
      MediaSourceInfo(
          supportsTranscoding: true,
          transcodingUrl: '/Videos/movie/master.m3u8'),
    ]);
    await expectLater(
        factory.prepare(itemId: 'movie', userId: 'user', isLive: false),
        throwsA(isA<IosPipSourceException>()));
    expect(releases, isEmpty);
  });
}
