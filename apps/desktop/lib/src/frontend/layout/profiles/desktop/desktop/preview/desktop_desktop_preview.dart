import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/tokens/desktop_desktop_tokens.dart';

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
      structuralLandmarks: <String>['main-canvas', 'capsule-dock'],
    );

Widget buildDesktopDesktopPreview(BuildContext context) =>
    const DesktopDesktopPreview();

/// A deterministic, non-interactive layout-picker thumbnail of the Desktop
/// shell: the conversation canvas above its persistent bottom dock.
final class DesktopDesktopPreview extends StatelessWidget {
  const DesktopDesktopPreview({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    return Semantics(
      container: true,
      image: true,
      label: desktopDesktopPreviewMetadata.styleIdentity,
      child: AspectRatio(
        aspectRatio: 16 / 10,
        child: DecoratedBox(
          key: const ValueKey<String>('desktop-desktop-preview'),
          decoration: BoxDecoration(
            color: colors.background,
            border: Border.all(color: colors.line),
            borderRadius: BorderRadius.circular(
              desktopDesktopTokens.cardRadius,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(
              desktopDesktopTokens.cardRadius,
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Positioned(
                  left: 8,
                  right: 8,
                  top: 8,
                  bottom: 34,
                  child: DecoratedBox(
                    key: const ValueKey<String>(
                      'desktop-desktop-preview-main-canvas',
                    ),
                    decoration: BoxDecoration(
                      color: colors.surfaceSunken,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: colors.line.withAlpha(90)),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Container(
                            key: const ValueKey<String>(
                              'desktop-preview-conversation-list',
                            ),
                            width: 76,
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: colors.surface,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Row(
                                  children: [
                                    for (var index = 0; index < 3; index++)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          right: 3,
                                        ),
                                        child: Icon(
                                          Icons.circle,
                                          size: 4,
                                          color: colors.textMuted,
                                        ),
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                for (var index = 0; index < 4; index++)
                                  Container(
                                    height: 12,
                                    margin: const EdgeInsets.only(bottom: 6),
                                    decoration: BoxDecoration(
                                      color: index == 0
                                          ? colors.primary.withAlpha(45)
                                          : colors.line.withAlpha(90),
                                      borderRadius: BorderRadius.circular(3),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                for (var index = 0; index < 3; index++)
                                  Padding(
                                    padding: const EdgeInsets.only(
                                      top: 10,
                                      bottom: 10,
                                    ),
                                    child: FractionallySizedBox(
                                      alignment: Alignment.centerLeft,
                                      widthFactor: index == 1 ? 0.7 : 0.9,
                                      child: Container(
                                        height: 5,
                                        color: colors.textMuted.withAlpha(70),
                                      ),
                                    ),
                                  ),
                                const Spacer(),
                                Container(
                                  key: const ValueKey<String>(
                                    'desktop-preview-composer',
                                  ),
                                  height: 17,
                                  decoration: BoxDecoration(
                                    color: colors.surface,
                                    borderRadius: BorderRadius.circular(5),
                                    border: Border.all(color: colors.line),
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
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 7),
                    child: Container(
                      key: const ValueKey<String>(
                        'desktop-desktop-preview-capsule-dock',
                      ),
                      width: 128,
                      height: 18,
                      decoration: BoxDecoration(
                        color: desktopDesktopSurfaceBlack,
                        borderRadius: BorderRadius.circular(5),
                        border: Border.all(
                          color: DesktopDesktopOnBlack.line,
                          width: 0.5,
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          for (var index = 0; index < 4; index++)
                            Container(
                              width: 9,
                              height: 9,
                              margin: const EdgeInsets.symmetric(
                                horizontal: 2.5,
                              ),
                              decoration: BoxDecoration(
                                color: index == 0
                                    ? DesktopDesktopOnBlack.text
                                    : DesktopDesktopOnBlack.textMuted,
                                borderRadius: BorderRadius.circular(2.5),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
