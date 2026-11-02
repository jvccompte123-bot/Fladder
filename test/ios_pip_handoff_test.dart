import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fladder/wrappers/pip_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('fladder/ios_pip');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late PipManager manager;
  late List<String> calls;
  bool startSucceeds = true;

  Future<void> event(String status, {int position = 0}) async {
    final completed = Completer<void>();
    messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall('state', {
        'status': status,
        'positionMs': position,
        'playing': true,
      })),
      (_) => completed.complete(),
    );
    await completed.future;
  }

  setUp(() {
    iosNativePipActive = false;
    calls = [];
    startSucceeds = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'isSupported') return true;
      if (call.method == 'start') {
        if (startSucceeds) await event('started');
        return startSucceeds;
      }
      return null;
    });
    manager = PipManager(client: IosPipClient());
  });
  tearDown(() async {
    await manager.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('reserves audio before pause and waits for pause before starting AVKit',
      () async {
    final paused = Completer<void>();
    final started = manager.enterIOSPlayback(
      mediaUrl: 'https://example.invalid/video.mp4',
      position: const Duration(seconds: 12),
      pause: () {
        expect(iosNativePipActive, isTrue);
        return paused.future;
      },
      resume: () async => fail('must not resume MPV while PiP owns playback'),
    );
    expect(calls, isEmpty);
    expect(
        await manager.enterIOSPlayback(
          mediaUrl: 'https://example.invalid/video.mp4',
          position: Duration.zero,
          pause: () async => fail('duplicate transfer'),
          resume: () async => fail('duplicate resume'),
        ),
        isFalse);
    paused.complete();
    expect(await started, isTrue);
    expect(iosNativePipActive, isTrue);
  });

  test('live TV reaches native PiP without seeking to the EPG position',
      () async {
    Map<dynamic, dynamic>? arguments;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'isSupported') return true;
      if (call.method == 'start') {
        arguments = call.arguments as Map;
        await event('started');
        return true;
      }
      return null;
    });
    expect(
        await manager.enterIOSPlayback(
          mediaUrl: 'https://example.invalid/live.m3u8',
          position: Duration.zero,
          isLive: true,
          pause: () async {},
          resume: () async {},
        ),
        isTrue);
    expect(arguments!['isLive'], isTrue);
    expect(arguments!['positionMs'], 0);
  });

  test('an AVFoundation error releases audio and resumes normal playback',
      () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'isSupported') return true;
      if (call.method == 'start') {
        throw PlatformException(
            code: 'ios_media_AVFoundationErrorDomain_-11828');
      }
      return null;
    });
    var resumed = 0;
    await expectLater(
        manager.enterIOSPlayback(
          mediaUrl: 'https://example.invalid/movie.m3u8',
          position: Duration.zero,
          pause: () async {},
          resume: () async {
            resumed++;
          },
        ),
        throwsA(isA<PlatformException>()));
    expect(resumed, 1);
    expect(iosNativePipActive, isFalse);
  });

  test('failed native start releases audio and resumes MPV once', () async {
    startSucceeds = false;
    var resumed = 0;
    expect(
        await manager.enterIOSPlayback(
          mediaUrl: 'https://example.invalid/video.mp4',
          position: Duration.zero,
          pause: () async {},
          resume: () async {
            expect(iosNativePipActive, isFalse);
            resumed++;
          },
        ),
        isFalse);
    expect(resumed, 1);
  });

  test(
      'native close restores position once; replacement waits and suppresses restore',
      () async {
    final restored = <IosPipRestoreEvent>[];
    final subscription = manager.iosRestoreEvents.listen(restored.add);
    await event('started');
    await event('stopped', position: 42000);
    await event('stopped', position: 42000);
    await Future<void>.delayed(Duration.zero);
    expect(restored.single.position, const Duration(seconds: 42));
    await event('started');
    var stopped = false;
    final stopping = manager.stopForNewPlayback().then((_) => stopped = true);
    await Future<void>.delayed(Duration.zero);
    expect(stopped, isFalse);
    await event('stopped', position: 50000);
    await stopping;
    expect(restored, hasLength(1));
    await subscription.cancel();
  });
}
