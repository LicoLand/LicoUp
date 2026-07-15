import 'package:flutter/material.dart';

import 'package:flutter_client/src/frontend/layout/layout_palette.dart';
import 'package:flutter_client/src/frontend/layout/profiles/bubble/mobile/bubble_mobile_tokens.dart';

Widget buildBubbleMobilePreview(BuildContext context) {
  return const BubbleMobilePreview();
}

/// A deterministic rendering made only from public profile metadata and theme.
final class BubbleMobilePreview extends StatelessWidget {
  const BubbleMobilePreview({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    return Semantics(
      key: const Key('bubble-mobile-preview'),
      container: true,
      image: true,
      label: bubbleMobileStyleIdentity,
      child: RepaintBoundary(
        child: AspectRatio(
          aspectRatio: 1.68,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.background,
              borderRadius: BorderRadius.circular(
                BubbleMobileMetrics.compactRadius,
              ),
              border: Border.all(color: colors.line, width: 1),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(
                BubbleMobileMetrics.compactRadius - 1,
              ),
              child: ExcludeSemantics(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final compact = constraints.maxWidth < 260;
                    return Row(
                      children: [
                        _BubblePreviewRail(compact: compact),
                        Expanded(
                          child: _BubblePreviewWorkspace(compact: compact),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _BubblePreviewRail extends StatelessWidget {
  const _BubblePreviewRail({required this.compact});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    return SizedBox(
      width: compact ? 27 : 34,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border(right: BorderSide(color: colors.line, width: 1)),
        ),
        child: Column(
          children: [
            SizedBox(height: compact ? 7 : 9),
            Container(
              width: compact ? 13 : 16,
              height: compact ? 13 : 16,
              decoration: BoxDecoration(
                color: colors.primary,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            SizedBox(height: compact ? 9 : 12),
            for (var index = 0; index < 4; index++) ...[
              Container(
                width: compact ? 18 : 23,
                height: compact ? 18 : 23,
                decoration: BoxDecoration(
                  color: index == 0
                      ? colors.primary.withAlpha(colors.isDark ? 52 : 34)
                      : Colors.transparent,
                  border: Border(
                    left: BorderSide(
                      color: index == 0 ? colors.primary : Colors.transparent,
                      width: 2,
                    ),
                  ),
                ),
                alignment: Alignment.center,
                child: Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: index == 0 ? colors.primary : colors.textMuted,
                    shape: index.isEven ? BoxShape.rectangle : BoxShape.circle,
                    borderRadius: index.isEven
                        ? BorderRadius.circular(1.5)
                        : null,
                  ),
                ),
              ),
              const SizedBox(height: 3),
            ],
          ],
        ),
      ),
    );
  }
}

final class _BubblePreviewWorkspace extends StatelessWidget {
  const _BubblePreviewWorkspace({required this.compact});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    return Column(
      children: [
        SizedBox(
          height: compact ? 26 : 32,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surface,
              border: Border(bottom: BorderSide(color: colors.line, width: 1)),
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: compact ? 7 : 10),
              child: Row(
                children: [
                  Text(
                    'BUBBLE',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: colors.primary,
                      fontSize: compact ? 7 : 8,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const Spacer(),
                  Container(
                    width: compact ? 28 : 38,
                    height: 4,
                    color: colors.line,
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              compact ? 7 : 10,
              compact ? 6 : 8,
              compact ? 7 : 10,
              0,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _BubblePreviewLine(
                  widthFactor: 0.34,
                  height: compact ? 4 : 5,
                  color: colors.textMuted.withAlpha(110),
                ),
                SizedBox(height: compact ? 5 : 7),
                Expanded(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.surfaceLow,
                      border: Border.all(color: colors.line, width: 1),
                    ),
                    child: Padding(
                      padding: EdgeInsets.all(compact ? 5 : 7),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _BubblePreviewLine(
                            widthFactor: 0.78,
                            height: 4,
                            color: colors.text.withAlpha(100),
                          ),
                          const SizedBox(height: 5),
                          _BubblePreviewLine(
                            widthFactor: 0.55,
                            height: 4,
                            color: colors.textMuted.withAlpha(72),
                          ),
                          const Spacer(),
                          Align(
                            alignment: Alignment.centerRight,
                            child: Container(
                              width: compact ? 54 : 72,
                              height: compact ? 18 : 22,
                              decoration: BoxDecoration(
                                color: colors.primary.withAlpha(
                                  colors.isDark ? 50 : 30,
                                ),
                                border: Border(
                                  left: BorderSide(
                                    color: colors.primary,
                                    width: 2,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                SizedBox(height: compact ? 4 : 6),
                Container(
                  height: compact ? 21 : 27,
                  decoration: BoxDecoration(
                    color: colors.surface,
                    border: Border.all(color: colors.line, width: 1),
                    borderRadius: BorderRadius.circular(
                      BubbleMobileMetrics.controlRadius,
                    ),
                  ),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Container(
                      margin: const EdgeInsets.all(3),
                      width: compact ? 18 : 22,
                      decoration: BoxDecoration(
                        color: colors.primary,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                ),
                SizedBox(height: compact ? 5 : 7),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

final class _BubblePreviewLine extends StatelessWidget {
  const _BubblePreviewLine({
    required this.widthFactor,
    required this.height,
    required this.color,
  });

  final double widthFactor;
  final double height;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      widthFactor: widthFactor,
      alignment: Alignment.centerLeft,
      child: SizedBox(
        height: height,
        child: ColoredBox(color: color),
      ),
    );
  }
}
