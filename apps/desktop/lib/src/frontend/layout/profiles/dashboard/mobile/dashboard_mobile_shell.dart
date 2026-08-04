import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/mobile/dashboard_mobile_tokens.dart';

Widget buildDashboardMobileCompactShell(
  BuildContext context,
  LayoutShellBuildContext data,
) {
  _validateEnvironment(data, LayoutViewportClass.compact);
  return _DashboardMobileShell(data: data, compact: true);
}

Widget buildDashboardMobileMediumShell(
  BuildContext context,
  LayoutShellBuildContext data,
) {
  _validateEnvironment(data, LayoutViewportClass.medium);
  return _DashboardMobileShell(data: data, compact: false);
}

void _validateEnvironment(
  LayoutShellBuildContext data,
  LayoutViewportClass viewport,
) {
  if (data.environment.surface != LayoutRuntimeSurface.mobile ||
      data.environment.viewport != viewport ||
      data.availableDestinations.isEmpty ||
      !data.availableDestinations.contains(data.activeDestination)) {
    throw const FormatException('dashboard_mobile_shell_contract_invalid');
  }
}

final class _DashboardMobileShell extends StatelessWidget {
  const _DashboardMobileShell({required this.data, required this.compact});

  final LayoutShellBuildContext data;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final environment = data.environment;
    final inheritedMedia = MediaQuery.maybeOf(context);
    final media = (inheritedMedia ?? const MediaQueryData()).copyWith(
      textScaler: TextScaler.linear(
        DashboardMobileMetrics.boundedTextScale(environment),
      ),
      disableAnimations:
          environment.reducedMotion ||
          (inheritedMedia?.disableAnimations ?? false),
    );

    return RestorationScope(
      restorationId:
          '$dashboardMobileRestorationPrefix.${environment.viewport.name}.shell',
      child: MediaQuery(
        data: media,
        child: FocusTraversalGroup(
          policy: OrderedTraversalPolicy(),
          child: LayoutBuilder(
            builder: (context, constraints) =>
                _buildConstrainedShell(context, constraints, environment),
          ),
        ),
      ),
    );
  }

  Widget _buildConstrainedShell(
    BuildContext context,
    BoxConstraints constraints,
    LayoutEnvironment environment,
  ) {
    final colors = Theme.of(context).colorScheme;
    final constraintWidth = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : environment.width;
    final adaptiveHorizontalPadding = math.min(
      DashboardMobileMetrics.horizontalPadding(environment),
      math.max(dashboardMobileTokens.spacingUnit, constraintWidth * 0.06),
    );
    final safeInsets = environment.safeInsets;
    final horizontalInsets =
        safeInsets.left + safeInsets.right + adaptiveHorizontalPadding * 2;
    final contentWidth = math.max(0.0, constraintWidth - horizontalInsets);
    final boundedContentWidth = math.min(
      dashboardMobileTokens.contentMaxWidth,
      contentWidth,
    );
    final topPadding =
        safeInsets.top +
        (compact
            ? dashboardMobileTokens.spacingUnit
            : dashboardMobileTokens.spacingUnit * 1.5);
    final bottomClearance = DashboardMobileMetrics.composerClearance(
      environment,
    );

    return ColoredBox(
      key: ValueKey<String>(
        'dashboard-mobile-${environment.viewport.name}-shell',
      ),
      color: colors.surface,
      child: Padding(
        padding: EdgeInsets.only(
          left: safeInsets.left + adaptiveHorizontalPadding,
          top: topPadding,
          right: safeInsets.right + adaptiveHorizontalPadding,
        ),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: boundedContentWidth),
            child: AnimatedPadding(
              key: const ValueKey<String>(
                'dashboard-mobile-composer-clearance',
              ),
              duration: DashboardMobileMetrics.motionDuration(environment),
              curve: Curves.easeOutCubic,
              padding: EdgeInsets.only(bottom: bottomClearance),
              child: compact
                  ? _DashboardCompactComposition(data: data)
                  : _DashboardMediumComposition(
                      data: data,
                      availableWidth: boundedContentWidth,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _DashboardCompactComposition extends StatelessWidget {
  const _DashboardCompactComposition({required this.data});

  final LayoutShellBuildContext data;

  @override
  Widget build(BuildContext context) => Column(
    key: const ValueKey<String>('dashboard-mobile-compact-card-stack'),
    children: [
      _CompactContextualNavigation(data: data),
      const SizedBox(height: DashboardMobileMetrics.compactStackGap),
      Expanded(
        child: data.components.panel(
          context,
          key: const ValueKey<String>(
            'dashboard-mobile-compact-destination-panel',
          ),
          emphasized: true,
          child: _DestinationFocusAnchor(data: data),
        ),
      ),
    ],
  );
}

final class _CompactContextualNavigation extends StatelessWidget {
  const _CompactContextualNavigation({required this.data});

  final LayoutShellBuildContext data;

  @override
  Widget build(BuildContext context) {
    final environment = data.environment;
    final colors = Theme.of(context).colorScheme;
    final activeLabel = data.destinationLabel(data.activeDestination);
    final interactiveExtent = DashboardMobileMetrics.interactiveExtent(
      environment,
    );
    final baseTitleStyle = Theme.of(context).textTheme.titleMedium;
    final titleStyle = baseTitleStyle?.copyWith(
      color: colors.onSurface,
      fontSize:
          (baseTitleStyle.fontSize ?? 16) *
          dashboardMobileTokens.typographyScale,
      fontWeight: FontWeight.w700,
    );

    return data.components.panel(
      context,
      key: const ValueKey<String>(
        'dashboard-mobile-compact-contextual-navigation',
      ),
      child: Semantics(
        container: true,
        explicitChildNodes: true,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: interactiveExtent),
          child: Row(
            children: [
              ExcludeSemantics(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.primaryContainer,
                    borderRadius: BorderRadius.circular(
                      dashboardMobileTokens.cardRadius * 0.6,
                    ),
                  ),
                  child: Padding(
                    padding: EdgeInsets.all(dashboardMobileTokens.spacingUnit),
                    child: Icon(
                      _destinationIcon(data.activeDestination),
                      color: colors.onPrimaryContainer,
                      size: 22,
                    ),
                  ),
                ),
              ),
              SizedBox(width: dashboardMobileTokens.spacingUnit * 1.5),
              Expanded(
                child: Text(
                  activeLabel,
                  key: const ValueKey<String>(
                    'dashboard-mobile-active-destination-label',
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: titleStyle,
                ),
              ),
              SizedBox(width: dashboardMobileTokens.spacingUnit),
              Focus(
                canRequestFocus:
                    environment.hasKeyboard || environment.hasPointer,
                child: PopupMenuButton<ClientSection>(
                  key: const ValueKey<String>(
                    'dashboard-mobile-compact-navigation-trigger',
                  ),
                  tooltip: activeLabel,
                  position: PopupMenuPosition.under,
                  enableFeedback: environment.hasTouch,
                  constraints: const BoxConstraints(minWidth: 224),
                  onSelected: data.onSelectDestination,
                  itemBuilder: (context) => [
                    for (final destination in data.availableDestinations)
                      PopupMenuItem<ClientSection>(
                        key: ValueKey<String>(
                          'dashboard-mobile-compact-navigation-${destination.name}',
                        ),
                        value: destination,
                        height: interactiveExtent,
                        child: Semantics(
                          selected: destination == data.activeDestination,
                          child: Row(
                            children: [
                              Icon(_destinationIcon(destination), size: 22),
                              SizedBox(
                                width: dashboardMobileTokens.spacingUnit * 1.5,
                              ),
                              Expanded(
                                child: Text(
                                  data.destinationLabel(destination),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (destination == data.activeDestination)
                                const Icon(Icons.check_rounded, size: 20),
                            ],
                          ),
                        ),
                      ),
                  ],
                  icon: const Icon(Icons.expand_more_rounded),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _DashboardMediumComposition extends StatelessWidget {
  const _DashboardMediumComposition({
    required this.data,
    required this.availableWidth,
  });

  final LayoutShellBuildContext data;
  final double availableWidth;

  @override
  Widget build(BuildContext context) {
    final environment = data.environment;
    final scaledNavigationWidth =
        DashboardMobileMetrics.mediumNavigationWidth +
        (DashboardMobileMetrics.boundedTextScale(environment) - 1) * 28;
    final navigationWidth = math.min(
      scaledNavigationWidth,
      math.max(168.0, availableWidth * 0.4),
    );

    return Row(
      key: const ValueKey<String>('dashboard-mobile-medium-card-stack'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: navigationWidth,
          child: _MediumContextualNavigation(data: data),
        ),
        const SizedBox(width: DashboardMobileMetrics.mediumStackGap),
        Expanded(
          child: data.components.panel(
            context,
            key: const ValueKey<String>(
              'dashboard-mobile-medium-destination-panel',
            ),
            emphasized: true,
            child: _DestinationFocusAnchor(data: data),
          ),
        ),
      ],
    );
  }
}

final class _MediumContextualNavigation extends StatelessWidget {
  const _MediumContextualNavigation({required this.data});

  final LayoutShellBuildContext data;

  @override
  Widget build(BuildContext context) {
    final interactiveExtent = DashboardMobileMetrics.interactiveExtent(
      data.environment,
    );
    final colors = Theme.of(context).colorScheme;
    return data.components.panel(
      context,
      key: const ValueKey<String>(
        'dashboard-mobile-medium-contextual-navigation',
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(
              data.destinationLabel(data.activeDestination),
              key: const ValueKey<String>(
                'dashboard-mobile-medium-active-destination-label',
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: colors.onSurface,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          SizedBox(height: dashboardMobileTokens.spacingUnit * 1.5),
          Expanded(
            child: SingleChildScrollView(
              key: const ValueKey<String>(
                'dashboard-mobile-medium-navigation-scroll',
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final destination in data.availableDestinations) ...[
                    ConstrainedBox(
                      constraints: BoxConstraints(minHeight: interactiveExtent),
                      child: data.components.navigationItem(
                        context,
                        key: ValueKey<String>(
                          'dashboard-mobile-medium-navigation-${destination.name}',
                        ),
                        icon: Icon(_destinationIcon(destination)),
                        label: data.destinationLabel(destination),
                        selected: destination == data.activeDestination,
                        onPressed: () => data.onSelectDestination(destination),
                      ),
                    ),
                    if (destination != data.availableDestinations.last)
                      SizedBox(height: dashboardMobileTokens.spacingUnit),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

final class _DestinationFocusAnchor extends StatelessWidget {
  const _DestinationFocusAnchor({required this.data});

  final LayoutShellBuildContext data;

  @override
  Widget build(BuildContext context) => Semantics(
    key: ValueKey<String>(
      'dashboard-mobile-destination-${data.activeDestination.name}',
    ),
    container: true,
    child: KeyedSubtree(
      key: ValueKey<String>(
        'dashboard-mobile-focus-${data.initialFocusTarget}',
      ),
      child: data.destination,
    ),
  );
}

IconData _destinationIcon(ClientSection destination) => switch (destination) {
  ClientSection.agents => Icons.hub_outlined,
  ClientSection.monitoring => Icons.monitor_heart_outlined,
  ClientSection.skillHub => Icons.auto_awesome_mosaic_outlined,
  ClientSection.pluginManagement => Icons.extension_outlined,
  ClientSection.mobileRelay => Icons.phonelink_ring_outlined,
  ClientSection.models => Icons.key_outlined,
  ClientSection.settings => Icons.tune_rounded,
};
