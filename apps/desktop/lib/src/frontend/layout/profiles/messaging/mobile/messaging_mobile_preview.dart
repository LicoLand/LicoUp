import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/mobile/messaging_mobile_tokens.dart';

Widget buildMessagingMobilePreview(BuildContext context) {
  return const MessagingMobilePreview();
}

/// A deterministic, non-interactive thumbnail of the Messaging mobile
/// surface: a destination rail, a header band, and grouped participant
/// message rows above a composer strip.
final class MessagingMobilePreview extends StatelessWidget {
  const MessagingMobilePreview({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    return Semantics(
      key: const Key('messaging-mobile-preview'),
      container: true,
      image: true,
      label: messagingMobileStyleIdentity,
      child: RepaintBoundary(
        child: AspectRatio(
          aspectRatio: 1.68,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.background,
              borderRadius: BorderRadius.circular(
                MessagingMobileMetrics.compactRadius,
              ),
              border: Border.all(color: colors.line, width: 1),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(
                MessagingMobileMetrics.compactRadius - 1,
              ),
              child: ExcludeSemantics(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final compact = constraints.maxWidth < 260;
                    return Row(
                      children: [
                        _MessagingPreviewRail(compact: compact),
                        Expanded(
                          child: _MessagingPreviewConversation(
                            compact: compact,
                          ),
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

final class _MessagingPreviewRail extends StatelessWidget {
  const _MessagingPreviewRail({required this.compact});

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
            SizedBox(height: compact ? 9 : 12),
            for (var index = 0; index < 4; index++) ...[
              Container(
                width: compact ? 18 : 23,
                height: compact ? 18 : 23,
                decoration: BoxDecoration(
                  color: index == 0
                      ? colors.primary.withAlpha(colors.isDark ? 52 : 34)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(5),
                ),
                alignment: Alignment.center,
                child: Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: index == 0 ? colors.accent : colors.textMuted,
                    shape: BoxShape.circle,
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

final class _MessagingPreviewConversation extends StatelessWidget {
  const _MessagingPreviewConversation({required this.compact});

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
                  Container(
                    width: compact ? 12 : 15,
                    height: compact ? 12 : 15,
                    decoration: BoxDecoration(
                      color: colors.primary.withAlpha(colors.isDark ? 52 : 34),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    width: compact ? 44 : 60,
                    height: 5,
                    color: colors.text.withAlpha(120),
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
                for (var group = 0; group < 2; group++) ...[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: compact ? 12 : 15,
                        height: compact ? 12 : 15,
                        decoration: BoxDecoration(
                          color: group == 1
                              ? colors.primary.withAlpha(
                                  colors.isDark ? 52 : 34,
                                )
                              : colors.line.withAlpha(170),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: compact ? 40 : 54,
                              height: 4,
                              color: colors.text.withAlpha(120),
                            ),
                            const SizedBox(height: 3),
                            Container(
                              width: double.infinity,
                              height: 4,
                              color: colors.textMuted.withAlpha(90),
                            ),
                            const SizedBox(height: 3),
                            FractionallySizedBox(
                              widthFactor: 0.7,
                              child: Container(
                                height: 4,
                                color: colors.textMuted.withAlpha(70),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: compact ? 6 : 8),
                ],
                const Spacer(),
                Container(
                  height: compact ? 21 : 27,
                  decoration: BoxDecoration(
                    color: colors.surface,
                    border: Border.all(color: colors.line, width: 1),
                    borderRadius: BorderRadius.circular(
                      MessagingMobileMetrics.controlRadius,
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
