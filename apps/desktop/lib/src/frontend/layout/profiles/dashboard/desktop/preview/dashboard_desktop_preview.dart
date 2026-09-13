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

/// Dashboard's floating sidebar, bottom navigation, and open conversation
/// canvas at the layout picker's fixed preview scale.
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
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width: constraints.maxWidth * 0.32,
                        child: _PreviewListColumn(colors: colors),
                      ),
                      SizedBox(width: constraints.maxWidth * 0.025),
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
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: colors.line.withAlpha(120), width: 0.5),
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
              Container(
                key: const ValueKey<String>('dashboard-preview-search'),
                height: unit * 1.2,
                margin: EdgeInsets.only(bottom: unit),
                decoration: BoxDecoration(
                  color: colors.surfaceLow,
                  border: Border.all(color: colors.line, width: 0.5),
                  borderRadius: BorderRadius.circular(unit * 0.6),
                ),
              ),
              for (var index = 0; index < 4; index++) ...[
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
              const Spacer(),
              Row(
                key: const ValueKey<String>(
                  'dashboard-preview-bottom-navigation',
                ),
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  for (final icon in [
                    Icons.apps_outlined,
                    Icons.forum_outlined,
                    Icons.settings_outlined,
                  ])
                    Icon(
                      icon,
                      size: unit * 1.1,
                      color: icon == Icons.forum_outlined
                          ? colors.primaryStrong
                          : colors.textMuted,
                    ),
                ],
              ),
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
    color: colors.background,
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
