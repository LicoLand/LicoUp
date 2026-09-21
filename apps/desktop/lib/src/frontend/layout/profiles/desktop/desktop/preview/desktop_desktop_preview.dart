import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/tokens/desktop_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';

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
        'split-panes',
        'bottom-dock',
        'conversation-column',
      ],
    );

Widget buildDesktopDesktopPreview(BuildContext context) =>
    const DesktopDesktopPreview();

/// A deterministic, non-interactive layout-picker thumbnail of the Desktop
/// shell: the main content pane on the left beside the narrow conversation
/// column on the right, and along the bottom the icon strip at the left and
/// the composer box at the right, aligned with the panes above them.
final class DesktopDesktopPreview extends StatelessWidget {
  const DesktopDesktopPreview({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    // Thumbnail, not material proof: surfaces use the palette's opaque card
    // colors so the structure reads at selector size in both themes.
    final cardFill = colors.surface;
    final cardLine = colors.line.withAlpha(colors.isDark ? 110 : 140);
    return Semantics(
      container: true,
      image: true,
      label: desktopDesktopPreviewMetadata.styleIdentity,
      child: AspectRatio(
        aspectRatio: 16 / 10,
        child: DecoratedBox(
          key: const ValueKey<String>('desktop-desktop-preview'),
          decoration: continuousHairlineDecoration(
            color: colors.background,
            stroke: colors.line,
            borderRadius: BorderRadius.circular(
              desktopDesktopTokens.cardRadius,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(
              desktopDesktopTokens.cardRadius,
            ),
            child: ColoredBox(
              color: DesktopDesktopGlass.veil(isDark: colors.isDark),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Column(
                  children: [
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Main content pane.
                          Expanded(
                            flex: 13,
                            child: DecoratedBox(
                              key: const ValueKey<String>(
                                'desktop-desktop-preview-main-canvas',
                              ),
                              decoration: continuousHairlineDecoration(
                                color: cardFill,
                                borderRadius: BorderRadius.circular(6),
                                stroke: cardLine,
                                strokeWidth: 0.5,
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(5),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Row(
                                      children: [
                                        for (var index = 0; index < 3; index++)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              right: 2,
                                            ),
                                            child: Icon(
                                              Icons.circle,
                                              size: 3,
                                              color: colors.textMuted,
                                            ),
                                          ),
                                      ],
                                    ),
                                    const SizedBox(height: 5),
                                    for (var index = 0; index < 3; index++)
                                      Container(
                                        height: 4,
                                        margin: const EdgeInsets.only(
                                          bottom: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: index == 0
                                              ? colors.primary.withAlpha(45)
                                              : colors.line.withAlpha(90),
                                          borderRadius: BorderRadius.circular(
                                            2,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          // Conversation column.
                          Expanded(
                            flex: 8,
                            child: KeyedSubtree(
                              key: const ValueKey<String>(
                                'desktop-desktop-preview-conversation',
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  const Spacer(),
                                  for (var index = 0; index < 2; index++)
                                    Align(
                                      alignment: index == 0
                                          ? Alignment.centerLeft
                                          : Alignment.centerRight,
                                      child: Container(
                                        height: 6,
                                        margin: const EdgeInsets.only(
                                          bottom: 3,
                                        ),
                                        width: index == 0 ? 34 : 44,
                                        decoration: BoxDecoration(
                                          color: index == 0
                                              ? colors.line.withAlpha(90)
                                              : colors.primary.withAlpha(60),
                                          borderRadius: BorderRadius.circular(
                                            3,
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
                    const SizedBox(height: 4),
                    SizedBox(
                      height: 14,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Icon strip.
                          Expanded(
                            flex: 13,
                            child: DecoratedBox(
                              key: const ValueKey<String>(
                                'desktop-desktop-preview-dock',
                              ),
                              decoration: BoxDecoration(
                                color: cardFill,
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceEvenly,
                                children: [
                                  for (var index = 0; index < 4; index++)
                                    Container(
                                      width: 7,
                                      height: 7,
                                      decoration: BoxDecoration(
                                        color: index == 1
                                            ? colors.accent
                                            : colors.textMuted,
                                        borderRadius: BorderRadius.circular(2),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          // Composer box.
                          Expanded(
                            flex: 8,
                            child: DecoratedBox(
                              key: const ValueKey<String>(
                                'desktop-desktop-preview-composer',
                              ),
                              decoration: continuousHairlineDecoration(
                                color: cardFill,
                                stroke: cardLine,
                                strokeWidth: 0.5,
                                borderRadius: BorderRadius.circular(5),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
