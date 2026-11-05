import 'package:flutter/material.dart';

/// Give secondary controls their own row before they collide with playback.
class PlayerControlsLayout extends StatelessWidget {
  const PlayerControlsLayout({
    super.key,
    required this.leading,
    required this.playback,
    required this.trailing,
    this.spacing = 6,
  });

  final List<Widget> leading;
  final List<Widget> playback;
  final List<Widget> trailing;
  final double spacing;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 1400) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: Wrap(spacing: 4, runSpacing: 4, children: leading)),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: Wrap(spacing: 8, runSpacing: 4, alignment: WrapAlignment.end, children: trailing),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: spacing,
                  runSpacing: 4,
                  children: playback,
                ),
              ],
            );
          }
          return Row(
            spacing: spacing,
            children: [
              Expanded(child: Row(spacing: 4, children: leading)),
              ...playback,
              Expanded(child: Row(spacing: 8, mainAxisAlignment: MainAxisAlignment.end, children: trailing)),
            ],
          );
        },
      );
}
