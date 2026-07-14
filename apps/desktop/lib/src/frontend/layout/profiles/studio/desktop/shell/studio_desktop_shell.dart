import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/desktop/tokens/studio_desktop_tokens.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

Widget buildStudioDesktopMediumShell(
  BuildContext context,
  LayoutShellBuildContext data,
) => StudioDesktopShell(data: data, expanded: false);

Widget buildStudioDesktopExpandedShell(
  BuildContext context,
  LayoutShellBuildContext data,
) => StudioDesktopShell(data: data, expanded: true);

/// Studio's docked desktop shell. It never owns destination or profile state;
/// it projects the immutable host context into a dense navigation workspace.
final class StudioDesktopShell extends StatelessWidget {
  const StudioDesktopShell({
    super.key,
    required this.data,
    required this.expanded,
  });

  final LayoutShellBuildContext data;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final environment = data.environment;
    final colors = context.licoColors;
    final bottomInset = math.max(
      environment.safeInsets.bottom,
      environment.keyboardInset,
    );

    final shell = ColoredBox(
      color: colors.background,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          environment.safeInsets.left,
          environment.safeInsets.top,
          environment.safeInsets.right,
          bottomInset,
        ),
        child: FocusTraversalGroup(
          policy: OrderedTraversalPolicy(),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final dividerWidth = constraints.maxWidth >= 1
                  ? StudioDesktopMetrics.hairline
                  : 0.0;
              final desiredRail = _railExtent(
                constraints.maxWidth,
                environment.textScale,
              );
              final railExtent = math.min(
                desiredRail,
                math.max(0.0, constraints.maxWidth - dividerWidth),
              );
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: railExtent,
                    child: _StudioContextRail(
                      data: data,
                      showHeader: constraints.maxHeight >= 96,
                      showCapabilities: constraints.maxHeight >= 48,
                    ),
                  ),
                  if (dividerWidth > 0)
                    ColoredBox(
                      color: colors.line,
                      child: SizedBox(width: dividerWidth),
                    ),
                  Expanded(
                    child: _StudioDockedWorkspace(
                      data: data,
                      expanded: expanded,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
    final media = MediaQuery.maybeOf(context);
    if (media == null ||
        media.disableAnimations ||
        !environment.reducedMotion) {
      return shell;
    }
    return MediaQuery(
      data: media.copyWith(disableAnimations: true),
      child: shell,
    );
  }

  double _railExtent(double availableWidth, double textScale) {
    if (availableWidth <= StudioDesktopMetrics.compactRailExtent * 3) {
      return math.max(0.0, availableWidth * 0.28);
    }
    if (!expanded || availableWidth < 760) {
      return StudioDesktopMetrics.compactRailExtent;
    }
    final scale = textScale.clamp(1.0, 1.32);
    return (data.tokens.navigationExtent * scale)
        .clamp(
          StudioDesktopMetrics.minimumLabeledRailExtent,
          StudioDesktopMetrics.maximumRailExtent,
        )
        .toDouble();
  }
}

final class _StudioContextRail extends StatelessWidget {
  const _StudioContextRail({
    required this.data,
    required this.showHeader,
    required this.showCapabilities,
  });

  final LayoutShellBuildContext data;
  final bool showHeader;
  final bool showCapabilities;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final itemHeight = math.max(
      data.environment.hasTouch
          ? 44.0
          : StudioDesktopMetrics.navigationItemExtent,
      StudioDesktopMetrics.navigationItemExtent *
          data.environment.textScale.clamp(1.0, 1.5).toDouble(),
    );

    return Semantics(
      container: true,
      explicitChildNodes: true,
      child: ColoredBox(
        key: const ValueKey<String>('studio-desktop-context-rail'),
        color: colors.surfaceLow,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showHeader)
              SizedBox(
                height: StudioDesktopMetrics.railHeaderExtent,
                child: _StudioRailHeader(data: data),
              ),
            Expanded(
              child: ListView.builder(
                key: const PageStorageKey<String>(
                  'studio-desktop-navigation-list',
                ),
                padding: EdgeInsets.symmetric(
                  vertical: data.tokens.spacingUnit,
                ),
                itemCount: data.availableDestinations.length,
                itemBuilder: (context, index) {
                  final destination = data.availableDestinations[index];
                  final label = data.destinationLabel(destination);
                  return Semantics(
                    sortKey: OrdinalSortKey(index.toDouble()),
                    child: FocusTraversalOrder(
                      order: NumericFocusOrder(index.toDouble()),
                      child: SizedBox(
                        height: itemHeight,
                        child: data.components.navigationItem(
                          context,
                          key: ValueKey<String>(
                            'studio-desktop-navigation-${destination.name}',
                          ),
                          icon: Icon(_iconFor(destination)),
                          label: label,
                          selected: destination == data.activeDestination,
                          onPressed: () =>
                              data.onSelectDestination(destination),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            if (showCapabilities)
              _StudioInputCapabilities(environment: data.environment),
          ],
        ),
      ),
    );
  }
}

final class _StudioRailHeader extends StatelessWidget {
  const _StudioRailHeader({required this.data});

  final LayoutShellBuildContext data;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return LayoutBuilder(
      builder: (context, constraints) {
        final showText =
            constraints.maxWidth >=
            StudioDesktopMetrics.minimumLabeledRailExtent;
        return DecoratedBox(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: colors.line)),
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: showText ? data.tokens.spacingUnit * 1.5 : 0,
            ),
            child: Row(
              mainAxisAlignment: showText
                  ? MainAxisAlignment.start
                  : MainAxisAlignment.center,
              children: [
                ExcludeSemantics(
                  child: Icon(
                    Icons.view_quilt_outlined,
                    size: 19,
                    color: colors.primaryStrong,
                  ),
                ),
                if (showText) ...[
                  SizedBox(width: data.tokens.spacingUnit),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'STUDIO',
                          maxLines: 1,
                          overflow: TextOverflow.fade,
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(
                                color: colors.textMuted,
                                fontSize: 9.5 * data.tokens.typographyScale,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1.35,
                              ),
                        ),
                        Text(
                          data.destinationLabel(data.activeDestination),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelMedium
                              ?.copyWith(
                                color: colors.text,
                                fontSize: 11.5 * data.tokens.typographyScale,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

final class _StudioInputCapabilities extends StatelessWidget {
  const _StudioInputCapabilities({required this.environment});

  final LayoutEnvironment environment;

  @override
  Widget build(BuildContext context) {
    final icons = <IconData>[
      if (environment.hasKeyboard) Icons.keyboard_alt_outlined,
      if (environment.hasPointer) Icons.mouse_outlined,
      if (environment.hasTouch) Icons.touch_app_outlined,
      if (environment.reducedMotion) Icons.motion_photos_off_outlined,
    ];
    if (icons.isEmpty) {
      return const SizedBox.shrink();
    }
    final colors = context.licoColors;
    return ExcludeSemantics(
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: colors.line)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Wrap(
            alignment: WrapAlignment.center,
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final icon in icons)
                Icon(icon, size: 14, color: colors.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}

final class _StudioDockedWorkspace extends StatelessWidget {
  const _StudioDockedWorkspace({required this.data, required this.expanded});

  final LayoutShellBuildContext data;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return ColoredBox(
      key: const ValueKey<String>('studio-desktop-docked-workspace'),
      color: colors.background,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final showToolbar =
              constraints.maxHeight >= StudioDesktopMetrics.toolbarExtent * 1.5;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (showToolbar)
                SizedBox(
                  height: StudioDesktopMetrics.toolbarExtent,
                  child: _StudioWorkspaceBar(data: data, expanded: expanded),
                ),
              Expanded(
                child: Semantics(
                  container: true,
                  explicitChildNodes: true,
                  sortKey: const OrdinalSortKey(1000),
                  child: FocusTraversalOrder(
                    order: const NumericFocusOrder(1000),
                    child: Focus(
                      key: ValueKey<String>(
                        'studio-focus-${data.initialFocusTarget}',
                      ),
                      canRequestFocus: data.environment.hasKeyboard,
                      child: RepaintBoundary(
                        key: ValueKey<String>(
                          'studio-desktop-content-${data.activeDestination.name}',
                        ),
                        child: data.destination,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

final class _StudioWorkspaceBar extends StatelessWidget {
  const _StudioWorkspaceBar({required this.data, required this.expanded});

  final LayoutShellBuildContext data;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final label = data.destinationLabel(data.activeDestination);
    return Semantics(
      header: true,
      label: label,
      child: DecoratedBox(
        key: const ValueKey<String>('studio-desktop-workspace-bar'),
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border(bottom: BorderSide(color: colors.line)),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: data.tokens.spacingUnit * 1.5,
          ),
          child: Row(
            children: [
              Container(width: 3, height: 18, color: colors.primary),
              SizedBox(width: data.tokens.spacingUnit),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: colors.text,
                    fontSize: 12 * data.tokens.typographyScale,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (expanded)
                ExcludeSemantics(
                  child: Icon(
                    Icons.vertical_split_outlined,
                    size: 17,
                    color: colors.textMuted,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

IconData _iconFor(ClientSection destination) => switch (destination) {
  ClientSection.controlPanel => Icons.grid_view_outlined,
  ClientSection.agents => Icons.account_tree_outlined,
  ClientSection.feed => Icons.dynamic_feed_outlined,
  ClientSection.monitoring => Icons.query_stats_outlined,
  ClientSection.mcpPlugins => Icons.extension_outlined,
  ClientSection.skillHub => Icons.hub_outlined,
  ClientSection.localRuntime => Icons.memory_outlined,
  ClientSection.mobileRelay => Icons.phonelink_outlined,
  ClientSection.settings => Icons.tune_outlined,
};
