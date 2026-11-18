import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/built_in_layout_spec.dart';
import 'package:licoup/src/contracts/presentation/layout_style.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';
import 'package:licoup/src/frontend/shared/ui/lico_preview_window.dart';

final class DashboardDesktopPreviewMetadata {
  const DashboardDesktopPreviewMetadata({
    required this.styleIdentity,
    required this.structuralLandmarks,
  });

  final String styleIdentity;
  final List<String> structuralLandmarks;
}

const DashboardDesktopPreviewMetadata dashboardCardPreviewMetadata =
    DashboardDesktopPreviewMetadata(
      styleIdentity: 'dashboard-channel-chat',
      structuralLandmarks: <String>[
        'traffic-light-row',
        'list-column',
        'chat-canvas',
      ],
    );

const DashboardDesktopPreviewMetadata dashboardPlainPreviewMetadata =
    DashboardDesktopPreviewMetadata(
      styleIdentity: 'dashboard-plain',
      structuralLandmarks: <String>['rail', 'list-column', 'chat-canvas'],
    );

Widget buildDashboardDesktopPreview(
  BuildContext context,
  LayoutStyleId? style,
) => style == BuiltInLayoutSpec.dashboardPlainStyleId
    ? const DashboardPlainPreview()
    : const DashboardDesktopPreview();

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
      label: dashboardCardPreviewMetadata.styleIdentity,
      child: LicoPreviewWindow(
        key: const ValueKey<String>('dashboard-desktop-preview'),
        colors: colors,
        child: LayoutBuilder(
          builder: (context, constraints) => Padding(
            padding: EdgeInsets.only(
              left: constraints.maxWidth * 0.015,
              right: constraints.maxWidth * 0.015,
              top: constraints.maxHeight * 0.024,
              bottom: constraints.maxHeight * 0.03,
            ),
            child: Stack(
              key: const ValueKey<String>('dashboard-preview-main-card'),
              children: [
                Padding(
                  padding: EdgeInsets.only(
                    left: constraints.maxWidth * 0.02,
                    top: constraints.maxHeight * 0.03,
                  ),
                  child: LicoPreviewWindow.trafficLights(
                    dot: constraints.maxHeight * 0.04,
                  ),
                ),
                Row(
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
              ],
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
    decoration: continuousHairlineDecoration(
      color: colors.isDark ? colors.surface : colors.surfaceLow,
      borderRadius: BorderRadius.circular(8),
      stroke: colors.line.withAlpha(120),
      strokeWidth: 0.5,
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
                decoration: continuousHairlineDecoration(
                  color: colors.surfaceLow,
                  stroke: colors.line,
                  strokeWidth: 0.5,
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

/// Dashboard's plain style at the layout picker's fixed preview scale:
/// the slim navigation rail, a flat list column on the window ground, and the
/// open conversation canvas.
final class DashboardPlainPreview extends StatelessWidget {
  const DashboardPlainPreview({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    return Semantics(
      container: true,
      image: true,
      label: dashboardPlainPreviewMetadata.styleIdentity,
      child: LicoPreviewWindow(
        key: const ValueKey<String>('dashboard-plain-preview'),
        colors: colors,
        child: LayoutBuilder(
          builder: (context, constraints) => Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: constraints.maxWidth * 0.1,
                child: _PreviewRail(colors: colors),
              ),
              Container(width: 0.5, color: colors.line.withAlpha(160)),
              SizedBox(
                width: constraints.maxWidth * 0.32,
                child: _PreviewFlatListColumn(colors: colors),
              ),
              Container(width: 0.5, color: colors.line.withAlpha(160)),
              Expanded(child: _PreviewChatCanvas(colors: colors)),
            ],
          ),
        ),
      ),
    );
  }
}

final class _PreviewRail extends StatelessWidget {
  const _PreviewRail({required this.colors});

  final LayoutPalette colors;

  @override
  Widget build(BuildContext context) => ColoredBox(
    key: const ValueKey<String>('dashboard-preview-rail'),
    color: colors.surfaceSunken,
    child: LayoutBuilder(
      builder: (context, constraints) {
        final unit = constraints.maxHeight / 18;
        return Padding(
          padding: EdgeInsets.symmetric(vertical: unit * 0.7),
          child: Column(
            children: [
              Container(
                key: const ValueKey<String>('dashboard-preview-rail-avatar'),
                width: unit * 1.3,
                height: unit * 1.3,
                decoration: BoxDecoration(
                  color: colors.text,
                  shape: BoxShape.circle,
                ),
              ),
              SizedBox(height: unit * 0.9),
              for (var index = 0; index < 3; index++) ...[
                Container(
                  width: unit * 1.2,
                  height: unit * 1.2,
                  decoration: BoxDecoration(
                    color: index == 0
                        ? colors.primary.withAlpha(colors.isDark ? 60 : 36)
                        : colors.line.withAlpha(120),
                    borderRadius: BorderRadius.circular(unit * 0.35),
                  ),
                ),
                SizedBox(height: unit * 0.7),
              ],
              const Spacer(),
              Container(
                width: unit * 1.2,
                height: unit * 1.2,
                decoration: BoxDecoration(
                  color: colors.line.withAlpha(120),
                  borderRadius: BorderRadius.circular(unit * 0.35),
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}

/// The plain style's flat list column: a title row with the compose
/// mark, the search capsule, and conversation rows — no traffic lights and no
/// bottom nav, since the rail owns both.
final class _PreviewFlatListColumn extends StatelessWidget {
  const _PreviewFlatListColumn({required this.colors});

  final LayoutPalette colors;

  @override
  Widget build(BuildContext context) => ColoredBox(
    key: const ValueKey<String>('dashboard-preview-plain-list'),
    color: colors.background,
    child: LayoutBuilder(
      builder: (context, constraints) {
        final unit = constraints.maxHeight / 18;
        return Padding(
          padding: EdgeInsets.all(unit * 0.8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                key: const ValueKey<String>(
                  'dashboard-preview-plain-title-row',
                ),
                padding: EdgeInsets.only(bottom: unit * 0.6),
                child: Row(
                  children: [
                    Container(
                      height: unit * 0.6,
                      width: constraints.maxWidth * 0.45,
                      color: colors.text.withAlpha(160),
                    ),
                    const Spacer(),
                    Container(
                      width: unit * 1.0,
                      height: unit * 1.0,
                      decoration: BoxDecoration(
                        color: colors.line.withAlpha(140),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                key: const ValueKey<String>('dashboard-preview-plain-search'),
                height: unit * 1.2,
                margin: EdgeInsets.only(bottom: unit),
                decoration: continuousHairlineDecoration(
                  color: colors.surfaceLow,
                  stroke: colors.line,
                  strokeWidth: 0.5,
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
            ],
          ),
        );
      },
    ),
  );
}
