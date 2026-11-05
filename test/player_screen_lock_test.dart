import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fladder/l10n/generated/app_localizations.dart';
import 'package:fladder/screens/video_player/components/player_screen_lock.dart';

void main() {
  void iosTestWidgets(String description, WidgetTesterCallback callback) =>
      testWidgets(description, callback, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  TestWidgetsFlutterBinding.ensureInitialized();
  const orientationChannel = MethodChannel('fladder/player_orientation');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<List<String>> orientations;
  String displayedOrientation = 'DeviceOrientation.landscapeRight';
  late int gestures;

  Widget app({List<DeviceOrientation> allowed = DeviceOrientation.values}) => MaterialApp(
        locale: const Locale('fr'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: PlayerScreenLock(
            allowedOrientations: allowed,
            child: Column(
              children: [
                const PlayerScreenLockButton(),
                Expanded(
                  child: GestureDetector(
                    key: const ValueKey('playback_gestures'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => gestures++,
                    onDoubleTap: () => gestures++,
                    onVerticalDragUpdate: (_) => gestures++,
                    onScaleUpdate: (_) => gestures++,
                    child: const SizedBox.expand(),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

  setUp(() {
    orientations = [];
    gestures = 0;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setPreferredOrientations') {
        orientations.add(List<String>.from(call.arguments as List));
      }
      return null;
    });
    messenger.setMockMethodCallHandler(orientationChannel, (_) async => displayedOrientation);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    messenger.setMockMethodCallHandler(orientationChannel, null);
  });

  for (final orientation in DeviceOrientation.values) {
    iosTestWidgets('locks the displayed $orientation, blocks touch and restores preferences', (tester) async {
      displayedOrientation = orientation.toString();
      const allowed = [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight];
      await tester.pumpWidget(app(allowed: allowed));
      await tester.tap(find.byKey(const ValueKey('player_screen_lock')));
      await tester.pumpAndSettle();
      expect(orientations.last, [orientation.toString()]);
      final surface = find.byKey(const ValueKey('playback_gestures'));
      final point = tester.getCenter(surface);
      expect(ModalRoute.of(tester.element(surface))!.popDisposition, RoutePopDisposition.doNotPop);
      await tester.tapAt(point);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tapAt(point);
      await tester.dragFrom(point, const Offset(0, -100));
      final finger1 = await tester.startGesture(point - const Offset(30, 0));
      final finger2 = await tester.startGesture(point + const Offset(30, 0), pointer: 2);
      await finger1.moveBy(const Offset(-40, 0));
      await finger2.moveBy(const Offset(40, 0));
      await finger1.up();
      await finger2.up();
      expect(gestures, 0);
      // An accidental tap on the lock must not unlock the player.
      final unlock = find.byKey(const ValueKey('player_screen_unlock'));
      await tester.tap(unlock);
      await tester.pumpAndSettle();
      expect(unlock, findsOneWidget);
      expect(orientations.last, [orientation.toString()]);
      await tester.longPress(unlock);
      await tester.pumpAndSettle();
      expect(unlock, findsNothing);
      expect(orientations.last, allowed.map((e) => e.toString()).toList());
      await tester.tapAt(point);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 350));
      expect(gestures, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(orientations.last, DeviceOrientation.values.map((e) => e.toString()).toList());
    });
  }

  iosTestWidgets('orientation read failure leaves the controls usable', (tester) async {
    messenger.setMockMethodCallHandler(orientationChannel, (_) async => throw PlatformException(code: 'unavailable'));
    await tester.pumpWidget(app());
    await tester.tap(find.byKey(const ValueKey('player_screen_lock')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('player_screen_unlock')), findsNothing);
    expect(find.text('Impossible de modifier le verrouillage. Réessayez.'), findsOneWidget);
    await tester.tapAt(tester.getCenter(find.byKey(const ValueKey('playback_gestures'))));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 350));
    expect(gestures, 1);
  });

  iosTestWidgets('leaving during the orientation lookup cannot lock the next screen', (tester) async {
    final pending = Completer<String>();
    messenger.setMockMethodCallHandler(orientationChannel, (_) => pending.future);
    await tester.pumpWidget(app());
    await tester.tap(find.byKey(const ValueKey('player_screen_lock')));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    pending.complete('DeviceOrientation.landscapeRight');
    await tester.pumpAndSettle();
    expect(orientations.every((request) => request.length == 4), isTrue);
    expect(tester.takeException(), isNull);
  });

  iosTestWidgets('updated preferences apply on unlock, not while locked', (tester) async {
    displayedOrientation = 'DeviceOrientation.landscapeLeft';
    await tester.pumpWidget(app());
    await tester.tap(find.byKey(const ValueKey('player_screen_lock')));
    await tester.pumpAndSettle();
    await tester.pumpWidget(app(allowed: [DeviceOrientation.portraitUp]));
    await tester.pumpAndSettle();
    expect(orientations.last, ['DeviceOrientation.landscapeLeft']);
    await tester.longPress(find.byKey(const ValueKey('player_screen_unlock')));
    await tester.pumpAndSettle();
    expect(orientations.last, ['DeviceOrientation.portraitUp']);
  });

  iosTestWidgets('cleanup runs after an in-flight platform lock', (tester) async {
    final pending = Completer<void>();
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setPreferredOrientations') {
        final request = List<String>.from(call.arguments as List);
        orientations.add(request);
        if (request.length == 1) await pending.future;
      }
      return null;
    });
    await tester.pumpWidget(app());
    await tester.tap(find.byKey(const ValueKey('player_screen_lock')));
    await tester.pump();
    expect(orientations.last.length, 1);
    await tester.pumpWidget(const SizedBox());
    pending.complete();
    await tester.pumpAndSettle();
    expect(orientations.last, DeviceOrientation.values.map((e) => e.toString()).toList());
    expect(tester.takeException(), isNull);
  });

  iosTestWidgets('failed platform lock does not disable the controls or cleanup', (tester) async {
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setPreferredOrientations') {
        final request = List<String>.from(call.arguments as List);
        orientations.add(request);
        if (request.length == 1) throw PlatformException(code: 'unavailable');
      }
      return null;
    });
    await tester.pumpWidget(app());
    await tester.tap(find.byKey(const ValueKey('player_screen_lock')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('player_screen_unlock')), findsNothing);
    await tester.tapAt(tester.getCenter(find.byKey(const ValueKey('playback_gestures'))));
    await tester.pump(const Duration(milliseconds: 350));
    expect(gestures, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(orientations.last, DeviceOrientation.values.map((e) => e.toString()).toList());
  });
}
