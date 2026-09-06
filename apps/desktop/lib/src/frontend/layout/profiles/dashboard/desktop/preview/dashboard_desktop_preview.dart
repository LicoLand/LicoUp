import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/tokens/dashboard_desktop_tokens.dart';

final class DashboardDesktopPreviewMetadata {
  const DashboardDesktopPreviewMetadata({
    required this.styleIdentity,
    required this.structuralLandmarks,
  });

  final String styleIdentity;
  final List<String> structuralLandmarks;
}

const DashboardDesktopPreviewMetadata dashboardDesktopPreviewMetadata =
    DashboardDesktopPreviewMetadata(
      styleIdentity: 'dashboard-channel-chat',
      structuralLandmarks: <String>[
        'traffic-light-row',
        'list-column',
        'chat-canvas',
      ],
    );

Widget buildDashboardDesktopPreview(BuildContext context) =>
    const DashboardDesktopPreview();

/// A deterministic, non-interactive layout-picker thumbnail of the Dashboard
/// shell. The live shell uses native frosted glass for the content region and
/// gutters; this preview approximates structure with flat palette fills for
/// the list column and chat canvas, with a traffic-light hint at the list
/// column's top-left.
final class DashboardDesktopPreview extends StatelessWidget {
  const DashboardDesktopPreview({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    return Semantics(
      container: true,
      image: true,
      label: dashboardDesktopPreviewMetadata.styleIdentity,
      child: AspectRatio(
        aspectRatio: 16 / 10,
        child: DecoratedBox(
          key: const ValueKey<String>('dashboard-desktop-preview'),
          decoration: BoxDecoration(
            color: colors.background,
            border: Border.all(color: colors.line),
            borderRadius: BorderRadius.circular(
              dashboardDesktopTokens.cardRadius,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(
              dashboardDesktopTokens.cardRadius,
            ),
            child: LayoutBuilder(
              builder: (context, constraints) => Padding(
                padding: EdgeInsets.only(
                  left: constraints.maxWidth * 0.015,
                  right: constraints.maxWidth * 0.015,
                  top: constraints.maxHeight * 0.024,
                  bottom: constraints.maxHeight * 0.03,
                ),
                child: Container(
                  key: const ValueKey<String>('dashboard-preview-main-card'),
                  decoration: BoxDecoration(
                    color: colors.isDark ? colors.surface : colors.surfaceLow,
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
                      Expanded(child: _PreviewChatCanvas(colors: colors)),
                    ],
                  ),
                ),
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
    key: const ValueKey<String>('dashboard-preview-list-column'),
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
              Padding(
                key: const ValueKey<String>('dashboard-preview-light-row'),
                padding: EdgeInsets.only(bottom: unit * 0.6),
                child: Row(
                  children: [
                    for (var index = 0; index < 3; index++) ...[
                      Container(
                        width: unit * 0.7,
                        height: unit * 0.7,
                        decoration: BoxDecoration(
                          color: colors.textMuted.withAlpha(110),
                          shape: BoxShape.circle,
                        ),
                      ),
                      if (index < 2) SizedBox(width: unit * 0.45),
                    ],
                  ],
                ),
              ),
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
    key: const ValueKey<String>('dashboard-preview-chat-canvas'),
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
