import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fladder/screens/video_player/components/player_controls_layout.dart';

void main() {
  for (final size in [
    const Size(320, 700),
    const Size(402, 874),
    const Size(760, 360),
    const Size(874, 402),
    const Size(1440, 900)
  ]) {
    testWidgets('controls have distinct tappable areas at $size', (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final pressed = <String>[];
      Widget button(String id, {double iconSize = 24}) => IconButton(
            key: ValueKey(id),
            onPressed: () => pressed.add(id),
            iconSize: iconSize,
            icon: const Icon(Icons.play_arrow),
          );
      final ids = [
        'menu',
        'pip',
        'subtitles',
        'audio',
        'previous',
        'chapterBack',
        'seekBack',
        'play',
        'seekForward',
        'chapterNext',
        'next',
        'quality'
      ];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SafeArea(
            minimum: const EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.bottomCenter,
              child: PlayerControlsLayout(
                leading: ids.take(4).map(button).toList(),
                playback: ids.skip(4).take(7).map((id) => button(id, iconSize: id == 'play' ? 38 : 30)).toList(),
                trailing: [button('quality')],
              ),
            ),
          ),
        ),
      ));
      expect(tester.takeException(), isNull);
      for (var i = 0; i < ids.length; i++) {
        final rect = tester.getRect(find.byKey(ValueKey(ids[i])));
        expect(rect.left, greaterThanOrEqualTo(16));
        expect(rect.right, lessThanOrEqualTo(size.width - 16));
        for (var j = i + 1; j < ids.length; j++) {
          expect(rect.overlaps(tester.getRect(find.byKey(ValueKey(ids[j])))), isFalse,
              reason: '${ids[i]} must not overlap ${ids[j]}');
        }
        await tester.tap(find.byKey(ValueKey(ids[i])));
      }
      expect(pressed, ids);
    });
  }
}
