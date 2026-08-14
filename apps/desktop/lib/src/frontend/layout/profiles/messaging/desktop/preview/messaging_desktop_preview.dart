import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';

final class MessagingDesktopPreviewMetadata {
  const MessagingDesktopPreviewMetadata({
    required this.styleIdentity,
    required this.structuralLandmarks,
  });

  final String styleIdentity;
  final List<String> structuralLandmarks;
}

const MessagingDesktopPreviewMetadata messagingDesktopPreviewMetadata =
    MessagingDesktopPreviewMetadata(
      styleIdentity: 'messaging-channel-chat',
      structuralLandmarks: <String>[
        'top-strip',
        'list-column',
        'chat-canvas',
      ],
    );

Widget buildMessagingDesktopPreview(BuildContext context) =>
    const MessagingDesktopPreview();

/// A deterministic, non-interactive layout-picker thumbnail of the Messaging
/// shell. The live shell uses native frosted glass for band and gutters; this
/// preview approximates structure with flat palette fills for the list column
/// and chat canvas.
final class MessagingDesktopPreview extends StatelessWidget {
  const MessagingDesktopPreview({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    return Semantics(
      container: true,
      image: true,
      label: messagingDesktopPreviewMetadata.styleIdentity,
      child: AspectRatio(
        aspectRatio: 16 / 10,
        child: DecoratedBox(
          key: const ValueKey<String>('messaging-desktop-preview'),
          decoration: BoxDecoration(
            color: colors.background,
            border: Border.all(color: colors.line),
            borderRadius: BorderRadius.circular(
              messagingDesktopTokens.cardRadius,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(
              messagingDesktopTokens.cardRadius,
            ),
            child: LayoutBuilder(
              builder: (context, constraints) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: constraints.maxHeight * 0.11,
                    child: ColoredBox(
                      key: const ValueKey<String>(
                        'messaging-preview-top-strip',
                      ),
                      color: Colors.transparent,
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: constraints.maxWidth * 0.02,
                        ),
                        child: Row(
                          children: [
                            for (var index = 0; index < 3; index++) ...[
                              Container(
                                width: constraints.maxWidth * 0.13,
                                height: constraints.maxHeight * 0.048,
                                decoration: BoxDecoration(
                                  color: index == 0
                                      ? (colors.isDark
                                            ? Colors.white.withAlpha(26)
                                            : Colors.black.withAlpha(16))
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(99),
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Container(
                                      width: constraints.maxHeight * 0.026,
                                      height: constraints.maxHeight * 0.026,
                                      decoration: BoxDecoration(
                                        color: index == 0
                                            ? colors.primary.withAlpha(
                                                colors.isDark ? 52 : 34,
                                              )
                                            : colors.line,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    SizedBox(
                                      width: constraints.maxWidth * 0.006,
                                    ),
                                    Container(
                                      width: constraints.maxWidth * 0.06,
                                      height: constraints.maxHeight * 0.016,
                                      color: colors.textMuted.withAlpha(130),
                                    ),
                                  ],
                                ),
                              ),
                              SizedBox(width: constraints.maxWidth * 0.008),
                            ],
                            const Spacer(),
                            Container(
                              width: constraints.maxWidth * 0.17,
                              height: constraints.maxHeight * 0.045,
                              decoration: BoxDecoration(
                                color: colors.line.withAlpha(140),
                                borderRadius: BorderRadius.circular(99),
                              ),
                            ),
                            SizedBox(width: constraints.maxWidth * 0.012),
                            Container(
                              width: constraints.maxHeight * 0.038,
                              height: constraints.maxHeight * 0.038,
                              decoration: BoxDecoration(
                                color: colors.textMuted.withAlpha(120),
                                shape: BoxShape.circle,
                              ),
                            ),
                            SizedBox(width: constraints.maxWidth * 0.008),
                            Container(
                              width: constraints.maxHeight * 0.038,
                              height: constraints.maxHeight * 0.038,
                              decoration: BoxDecoration(
                                color: colors.primary.withAlpha(
                                  colors.isDark ? 52 : 34,
                                ),
                                shape: BoxShape.circle,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(
                        left: constraints.maxWidth * 0.015,
                        right: constraints.maxWidth * 0.015,
                        bottom: constraints.maxHeight * 0.03,
                      ),
                      child: Container(
                        key: const ValueKey<String>(
                          'messaging-preview-main-card',
                        ),
                        decoration: BoxDecoration(
                          color: colors.isDark
                              ? colors.surface
                              : colors.surfaceLow,
                          borderRadius: BorderRadius.circular(
                            constraints.maxHeight * 0.06,
                          ),
                          border: Border.all(
                            color: colors.line.withAlpha(100),
                            width: 0.5,
                          ),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SizedBox(
                              width: constraints.maxWidth * 0.32,
                              child: _PreviewListColumn(colors: colors),
                            ),
                            Expanded(
                              child: _PreviewChatCanvas(colors: colors),
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
      ),
    );
  }
}

final class _PreviewListColumn extends StatelessWidget {
  const _PreviewListColumn({required this.colors});

  final LayoutPalette colors;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey<String>('messaging-preview-list-column'),
    decoration: BoxDecoration(
      color: colors.isDark ? colors.surface : colors.surfaceLow,
      border: Border(
        right: BorderSide(color: colors.line.withAlpha(80), width: 0.5),
      ),
    ),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final unit = constraints.maxHeight / 18;
        return Padding(
          padding: EdgeInsets.all(unit * 0.8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var index = 0; index < 5; index++) ...[
                Row(
                  children: [
                    Container(
                      width: unit * 1.6,
                      height: unit * 1.6,
                      decoration: BoxDecoration(
                        color: index == 0
                            ? colors.primary.withAlpha(colors.isDark ? 60 : 36)
                            : colors.line,
                        shape: BoxShape.circle,
                      ),
                    ),
                    SizedBox(width: unit * 0.5),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            height: unit * 0.55,
                            width: constraints.maxWidth * 0.5,
                            color: colors.text.withAlpha(140),
                          ),
                          SizedBox(height: unit * 0.3),
                          Container(
                            height: unit * 0.45,
                            width: constraints.maxWidth * 0.35,
                            color: colors.textMuted.withAlpha(110),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                SizedBox(height: unit * 0.9),
              ],
            ],
          ),
        );
      },
    ),
  );
}

final class _PreviewChatCanvas extends StatelessWidget {
  const _PreviewChatCanvas({required this.colors});

  final LayoutPalette colors;

  @override
  Widget build(BuildContext context) => ColoredBox(
    key: const ValueKey<String>('messaging-preview-chat-canvas'),
    color: colors.isDark ? colors.surfaceLow : colors.surface,
    child: LayoutBuilder(
      builder: (context, constraints) {
        final unit = constraints.maxHeight / 18;
        return Padding(
          padding: EdgeInsets.all(unit * 1.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var group = 0; group < 3; group++) ...[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: unit * 1.6,
                      height: unit * 1.6,
                      decoration: BoxDecoration(
                        color: group == 1
                            ? colors.primary.withAlpha(colors.isDark ? 60 : 36)
                            : colors.line.withAlpha(180),
                        shape: BoxShape.circle,
                      ),
                    ),
                    SizedBox(width: unit * 0.5),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            height: unit * 0.55,
                            width: constraints.maxWidth * 0.4,
                            color: colors.text.withAlpha(150),
                          ),
                          SizedBox(height: unit * 0.35),
                          Container(
                            height: unit * 0.5,
                            width: constraints.maxWidth * 0.7,
                            color: colors.textMuted.withAlpha(110),
                          ),
                          SizedBox(height: unit * 0.25),
                          Container(
                            height: unit * 0.5,
                            width: constraints.maxWidth * 0.55,
                            color: colors.textMuted.withAlpha(90),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                SizedBox(height: unit * 1.1),
              ],
              const Spacer(),
              Container(
                height: unit * 1.7,
                decoration: BoxDecoration(
                  color: colors.line.withAlpha(120),
                  borderRadius: BorderRadius.circular(unit * 0.5),
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}
