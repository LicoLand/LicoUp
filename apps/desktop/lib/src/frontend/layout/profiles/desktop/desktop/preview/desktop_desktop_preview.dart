import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';
import 'package:licoup/src/frontend/shared/ui/lico_preview_window.dart';
import 'package:licoup/src/contracts/presentation/layout_style.dart';

final class DesktopDesktopPreviewMetadata {
  const DesktopDesktopPreviewMetadata({
    required this.styleIdentity,
    required this.structuralLandmarks,
  });

  final String styleIdentity;
  final List<String> structuralLandmarks;
}

const DesktopDesktopPreviewMetadata desktopDesktopPreviewMetadata =
    DesktopDesktopPreviewMetadata(
      styleIdentity: 'spacious-card-desktop',
      structuralLandmarks: <String>[
        'work-area',
        'floating-dock',
        'chat-sidebar',
      ],
    );

Widget buildDesktopDesktopPreview(BuildContext context, LayoutStyleId? style) =>
    const DesktopDesktopPreview();

/// A deterministic, non-interactive layout-picker thumbnail of the Desktop
/// shell: the work-area card on the left with its title row and the floating
/// dock at its bottom, beside the chat sidebar card with its avatar column,
/// messages and composer.
final class DesktopDesktopPreview extends StatelessWidget {
  const DesktopDesktopPreview({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    // Thumbnail, not material proof: surfaces use the palette's opaque card
    // colors so the structure reads at selector size in both themes.
    final cardLine = colors.line.withAlpha(colors.isDark ? 110 : 140);
    Decoration card() => LicoPreviewWindow.infoCard(colors);
    Widget bar(double width, Color color, {double height = 4}) => Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(height / 2),
      ),
    );
    return Semantics(
      container: true,
      image: true,
      label: desktopDesktopPreviewMetadata.styleIdentity,
      child: LicoPreviewWindow(
        key: const ValueKey<String>('desktop-desktop-preview'),
        colors: colors,
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 13,
                child: DecoratedBox(
                  key: const ValueKey<String>(
                    'desktop-desktop-preview-main-canvas',
                  ),
                  decoration: card(),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            for (var index = 0; index < 3; index++)
                              Padding(
                                padding: const EdgeInsets.only(right: 2),
                                child: Icon(
                                  Icons.circle,
                                  size: 3,
                                  color: colors.textMuted,
                                ),
                              ),
                            const SizedBox(width: 4),
                            bar(5, colors.primary.withAlpha(120), height: 5),
                            const SizedBox(width: 3),
                            bar(22, colors.line.withAlpha(120)),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Expanded(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              for (var index = 0; index < 3; index++)
                                Container(
                                  width: 16,
                                  height: index == 1 ? 18 : 10,
                                  decoration: BoxDecoration(
                                    color: index == 1
                                        ? colors.primary.withAlpha(45)
                                        : colors.line.withAlpha(90),
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        Center(
                          child: Container(
                            key: const ValueKey<String>(
                              'desktop-desktop-preview-dock',
                            ),
                            height: 10,
                            padding: const EdgeInsets.symmetric(horizontal: 3),
                            decoration: continuousHairlineDecoration(
                              color: colors.background,
                              borderRadius: BorderRadius.circular(4),
                              stroke: cardLine,
                              strokeWidth: 0.5,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                for (var index = 0; index < 6; index++)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 1,
                                    ),
                                    child: Container(
                                      width: 5,
                                      height: 5,
                                      decoration: BoxDecoration(
                                        color: index == 0
                                            ? colors.primary
                                            : colors.textMuted,
                                        borderRadius: BorderRadius.circular(
                                          1.5,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                flex: 7,
                child: DecoratedBox(
                  key: const ValueKey<String>(
                    'desktop-desktop-preview-conversation',
                  ),
                  decoration: card(),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(3),
                        child: Column(
                          children: [
                            for (var index = 0; index < 4; index++)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 3),
                                child: Container(
                                  width: 6,
                                  height: 6,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: index == 0
                                        ? colors.primary.withAlpha(140)
                                        : colors.line.withAlpha(120),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(1, 4, 4, 4),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              bar(24, colors.line.withAlpha(120)),
                              const Spacer(),
                              for (var index = 0; index < 2; index++)
                                Align(
                                  alignment: index == 0
                                      ? Alignment.centerLeft
                                      : Alignment.centerRight,
                                  child: Padding(
                                    padding: const EdgeInsets.only(bottom: 3),
                                    child: bar(
                                      index == 0 ? 22 : 28,
                                      index == 0
                                          ? colors.line.withAlpha(90)
                                          : colors.primary.withAlpha(60),
                                      height: 6,
                                    ),
                                  ),
                                ),
                              const SizedBox(height: 2),
                              Container(
                                key: const ValueKey<String>(
                                  'desktop-desktop-preview-composer',
                                ),
                                height: 8,
                                decoration: continuousHairlineDecoration(
                                  color: colors.background,
                                  stroke: cardLine,
                                  strokeWidth: 0.5,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
