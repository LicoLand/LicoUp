import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/workbench/mobile/workbench_mobile_tokens.dart';

Widget buildWorkbenchMobileCompactShell(
  BuildContext context,
  LayoutShellBuildContext data,
) {
  _validateEnvironment(data, LayoutViewportClass.compact);
  return _WorkbenchMobileShell(data: data, compact: true);
}

Widget buildWorkbenchMobileMediumShell(
  BuildContext context,
  LayoutShellBuildContext data,
) {
  _validateEnvironment(data, LayoutViewportClass.medium);
  return _WorkbenchMobileShell(data: data, compact: false);
}

void _validateEnvironment(
  LayoutShellBuildContext data,
  LayoutViewportClass viewport,
) {
  if (data.environment.surface != LayoutRuntimeSurface.mobile ||
      data.environment.viewport != viewport ||
      data.availableDestinations.isEmpty ||
      !data.availableDestinations.contains(data.activeDestination)) {
    throw const FormatException('workbench_mobile_shell_contract_invalid');
  }
}

final class _WorkbenchMobileShell extends StatelessWidget {
  const _WorkbenchMobileShell({required this.data, required this.compact});

  final LayoutShellBuildContext data;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final environment = data.environment;
    final inheritedMedia = MediaQuery.maybeOf(context);
    final media = (inheritedMedia ?? const MediaQueryData()).copyWith(
      textScaler: TextScaler.linear(
        WorkbenchMobileMetrics.boundedTextScale(environment),
      ),
      disableAnimations:
          environment.reducedMotion ||
          (inheritedMedia?.disableAnimations ?? false),
    );

    return RestorationScope(
      restorationId:
          '$workbenchMobileRestorationPrefix.${environment.viewport.name}.shell',
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
      WorkbenchMobileMetrics.horizontalPadding(environment),
      math.max(workbenchMobileTokens.spacingUnit, constraintWidth * 0.06),
    );
    final safeInsets = environment.safeInsets;
    final horizontalInsets =
        safeInsets.left + safeInsets.right + adaptiveHorizontalPadding * 2;
    final contentWidth = math.max(0.0, constraintWidth - horizontalInsets);
    final boundedContentWidth = math.min(
      workbenchMobileTokens.contentMaxWidth,
      contentWidth,
    );
    final topPadding =
        safeInsets.top +
        (compact
            ? workbenchMobileTokens.spacingUnit
            : workbenchMobileTokens.spacingUnit * 1.5);
    final bottomClearance = WorkbenchMobileMetrics.composerClearance(
      environment,
    );

    return ColoredBox(
      key: ValueKey<String>(
        'workbench-mobile-${environment.viewport.name}-shell',
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
                'workbench-mobile-composer-clearance',
              ),
              duration: WorkbenchMobileMetrics.motionDuration(environment),
              curve: Curves.easeOutCubic,
              padding: EdgeInsets.only(bottom: bottomClearance),
              child: compact
                  ? _WorkbenchCompactComposition(data: data)
                  : _WorkbenchMediumComposition(
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

final class _WorkbenchCompactComposition extends StatelessWidget {
  const _WorkbenchCompactComposition({required this.data});

  final LayoutShellBuildContext data;

  @override
  Widget build(BuildContext context) => Column(
    key: const ValueKey<String>('workbench-mobile-compact-card-stack'),
    children: [
      _CompactContextualNavigation(data: data),
      const SizedBox(height: WorkbenchMobileMetrics.compactStackGap),
      Expanded(
        child: data.components.panel(
          context,
          key: const ValueKey<String>(
            'workbench-mobile-compact-destination-panel',
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
    final interactiveExtent = WorkbenchMobileMetrics.interactiveExtent(
      environment,
    );
    final baseTitleStyle = Theme.of(context).textTheme.titleMedium;
    final titleStyle = baseTitleStyle?.copyWith(
      color: colors.onSurface,
      fontSize:
          (baseTitleStyle.fontSize ?? 16) *
          workbenchMobileTokens.typographyScale,
      fontWeight: FontWeight.w700,
    );

    return data.components.panel(
      context,
      key: const ValueKey<String>(
        'workbench-mobile-compact-contextual-navigation',
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
                      workbenchMobileTokens.cardRadius * 0.6,
                    ),
                  ),
                  child: Padding(
                    padding: EdgeInsets.all(workbenchMobileTokens.spacingUnit),
                    child: Icon(
                      _destinationIcon(data.activeDestination),
                      color: colors.onPrimaryContainer,
                      size: 22,
                    ),
                  ),
                ),
              ),
              SizedBox(width: workbenchMobileTokens.spacingUnit * 1.5),
              Expanded(
                child: Text(
                  activeLabel,
                  key: const ValueKey<String>(
                    'workbench-mobile-active-destination-label',
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: titleStyle,
                ),
              ),
              SizedBox(width: workbenchMobileTokens.spacingUnit),
              Focus(
                canRequestFocus:
                    environment.hasKeyboard || environment.hasPointer,
                child: PopupMenuButton<ClientSection>(
                  key: const ValueKey<String>(
                    'workbench-mobile-compact-navigation-trigger',
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
                          'workbench-mobile-compact-navigation-${destination.name}',
                        ),
                        value: destination,
                        height: interactiveExtent,
                        child: Semantics(
                          selected: destination == data.activeDestination,
                          child: Row(
                            children: [
                              Icon(_destinationIcon(destination), size: 22),
                              SizedBox(
                                width: workbenchMobileTokens.spacingUnit * 1.5,
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

final class _WorkbenchMediumComposition extends StatelessWidget {
  const _WorkbenchMediumComposition({
    required this.data,
    required this.availableWidth,
  });

  final LayoutShellBuildContext data;
  final double availableWidth;

  @override
  Widget build(BuildContext context) {
    final environment = data.environment;
    final scaledNavigationWidth =
        WorkbenchMobileMetrics.mediumNavigationWidth +
        (WorkbenchMobileMetrics.boundedTextScale(environment) - 1) * 28;
    final navigationWidth = math.min(
      scaledNavigationWidth,
      math.max(168.0, availableWidth * 0.4),
    );

    return Row(
      key: const ValueKey<String>('workbench-mobile-medium-card-stack'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: navigationWidth,
          child: _MediumContextualNavigation(data: data),
        ),
        const SizedBox(width: WorkbenchMobileMetrics.mediumStackGap),
        Expanded(
          child: data.components.panel(
            context,
            key: const ValueKey<String>(
              'workbench-mobile-medium-destination-panel',
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
    final interactiveExtent = WorkbenchMobileMetrics.interactiveExtent(
      data.environment,
    );
    final colors = Theme.of(context).colorScheme;
    return data.components.panel(
      context,
      key: const ValueKey<String>(
        'workbench-mobile-medium-contextual-navigation',
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(
              data.destinationLabel(data.activeDestination),
              key: const ValueKey<String>(
                'workbench-mobile-medium-active-destination-label',
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: colors.onSurface,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          SizedBox(height: workbenchMobileTokens.spacingUnit * 1.5),
          Expanded(
            child: SingleChildScrollView(
              key: const ValueKey<String>(
                'workbench-mobile-medium-navigation-scroll',
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
                          'workbench-mobile-medium-navigation-${destination.name}',
                        ),
                        icon: Icon(_destinationIcon(destination)),
                        label: data.destinationLabel(destination),
                        selected: destination == data.activeDestination,
                        onPressed: () => data.onSelectDestination(destination),
                      ),
                    ),
                    if (destination != data.availableDestinations.last)
                      SizedBox(height: workbenchMobileTokens.spacingUnit),
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
      'workbench-mobile-destination-${data.activeDestination.name}',
    ),
    container: true,
    child: KeyedSubtree(
      key: ValueKey<String>(
        'workbench-mobile-focus-${data.initialFocusTarget}',
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
  ClientSection.settings => Icons.tune_rounded,
};
