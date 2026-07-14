import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';

Widget buildWorkbenchDesktopMediumShell(
  BuildContext context,
  LayoutShellBuildContext data,
) => _WorkbenchDesktopShell(data: data, expanded: false);

Widget buildWorkbenchDesktopExpandedShell(
  BuildContext context,
  LayoutShellBuildContext data,
) => _WorkbenchDesktopShell(data: data, expanded: true);

final class _WorkbenchDesktopShell extends StatelessWidget {
  const _WorkbenchDesktopShell({required this.data, required this.expanded});

  final LayoutShellBuildContext data;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    if (data.environment.surface != LayoutRuntimeSurface.desktop) {
      throw const FormatException('workbench_desktop_surface_invalid');
    }
    final colors = Theme.of(context).colorScheme;
    final strings = LicoStrings.of(context);
    final tokens = data.tokens;

    return LayoutBuilder(
      builder: (context, constraints) {
        final outerInsets = _boundedOuterInsets(
          constraints: constraints,
          environment: data.environment,
          base: tokens.spacingUnit * (expanded ? 3 : 2),
        );
        return Semantics(
          key: ValueKey<String>(
            'workbench-desktop-${expanded ? 'expanded' : 'medium'}-shell',
          ),
          container: true,
          label:
              '${strings.appTitle}, ${data.destinationLabel(data.activeDestination)}',
          child: ColoredBox(
            color: colors.surfaceContainerLowest,
            child: Padding(
              padding: outerInsets,
              child: FocusTraversalGroup(
                policy: OrderedTraversalPolicy(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    FocusTraversalOrder(
                      order: const NumericFocusOrder(0),
                      child: _CommandRegion(data: data, expanded: expanded),
                    ),
                    SizedBox(height: tokens.spacingUnit * 1.5),
                    _DestinationStrip(data: data),
                    SizedBox(height: tokens.spacingUnit * (expanded ? 2.5 : 2)),
                    Expanded(
                      child: FocusTraversalOrder(
                        order: const NumericFocusOrder(100),
                        child: _FloatingWorkspace(
                          data: data,
                          expanded: expanded,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

final class _CommandRegion extends StatelessWidget {
  const _CommandRegion({required this.data, required this.expanded});

  final LayoutShellBuildContext data;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final tokens = data.tokens;

    return data.components.panel(
      context,
      key: const ValueKey<String>('workbench-desktop-command-region'),
      emphasized: true,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: tokens.spacingUnit * (expanded ? 2.5 : 2),
          vertical: tokens.spacingUnit * 1.5,
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final condensed =
                !expanded ||
                constraints.maxWidth < 820 ||
                data.environment.textScale > 1.35;
            return Semantics(
              container: true,
              label: strings.command,
              child: Row(
                children: [
                  _WorkbenchMark(showLabel: !condensed),
                  SizedBox(width: tokens.spacingUnit * 1.5),
                  Expanded(child: _CommandField(data: data)),
                  if (!condensed) ...[
                    SizedBox(width: tokens.spacingUnit * 1.5),
                    _ActiveDestinationBadge(data: data),
                  ],
                  if (data.environment.hasKeyboard && !condensed) ...[
                    SizedBox(width: tokens.spacingUnit),
                    _KeyboardCapabilityBadge(label: strings.command),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

final class _WorkbenchMark extends StatelessWidget {
  const _WorkbenchMark({required this.showLabel});

  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final strings = LicoStrings.of(context);
    return ExcludeSemantics(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: colors.primaryContainer,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Padding(
              padding: const EdgeInsets.all(11),
              child: Icon(
                Icons.space_dashboard_rounded,
                size: 22,
                color: colors.onPrimaryContainer,
              ),
            ),
          ),
          if (showLabel) ...[
            const SizedBox(width: 12),
            Text(
              strings.appTitle,
              maxLines: 1,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: -0.25,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

final class _CommandField extends StatelessWidget {
  const _CommandField({required this.data});

  final LayoutShellBuildContext data;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final strings = LicoStrings.of(context);
    final tokens = data.tokens;
    return data.components.fieldFrame(
      context,
      key: const ValueKey<String>('workbench-desktop-command-field'),
      semanticLabel: strings.globalSearchHint,
      child: ExcludeSemantics(
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: tokens.spacingUnit * 1.5,
            vertical: tokens.spacingUnit * 1.25,
          ),
          child: Row(
            children: [
              Icon(
                Icons.manage_search_rounded,
                size: 21,
                color: colors.onSurfaceVariant,
              ),
              SizedBox(width: tokens.spacingUnit),
              Expanded(
                child: Text(
                  strings.globalSearchHint,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _ActiveDestinationBadge extends StatelessWidget {
  const _ActiveDestinationBadge({required this.data});

  final LayoutShellBuildContext data;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      label: data.destinationLabel(data.activeDestination),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.secondaryContainer,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          child: ExcludeSemantics(
            child: Text(
              data.destinationLabel(data.activeDestination),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: colors.onSecondaryContainer,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _KeyboardCapabilityBadge extends StatelessWidget {
  const _KeyboardCapabilityBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: colors.outlineVariant),
          ),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: ExcludeSemantics(
              child: Icon(
                Icons.keyboard_command_key_rounded,
                size: 19,
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _DestinationStrip extends StatelessWidget {
  const _DestinationStrip({required this.data});

  final LayoutShellBuildContext data;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final tokens = data.tokens;
    return Semantics(
      key: const ValueKey<String>('workbench-desktop-destination-strip'),
      container: true,
      label: strings.features,
      explicitChildNodes: true,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        child: Row(
          children: [
            for (
              var index = 0;
              index < data.availableDestinations.length;
              index++
            ) ...[
              if (index > 0) SizedBox(width: tokens.spacingUnit),
              FocusTraversalOrder(
                order: NumericFocusOrder(index + 1),
                child: data.components.navigationItem(
                  context,
                  key: ValueKey<String>(
                    'workbench-desktop-nav-${data.availableDestinations[index].name}',
                  ),
                  icon: Icon(
                    _destinationIcon(data.availableDestinations[index]),
                  ),
                  label: data.destinationLabel(
                    data.availableDestinations[index],
                  ),
                  selected:
                      data.availableDestinations[index] ==
                      data.activeDestination,
                  onPressed: () => data.onSelectDestination(
                    data.availableDestinations[index],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

final class _FloatingWorkspace extends StatelessWidget {
  const _FloatingWorkspace({required this.data, required this.expanded});

  final LayoutShellBuildContext data;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final tokens = data.tokens;
    final duration = data.environment.reducedMotion
        ? Duration.zero
        : tokens.motionDuration;
    final inset = tokens.spacingUnit * (expanded ? 0.5 : 0);

    return AnimatedPadding(
      duration: duration,
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.symmetric(horizontal: inset),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: tokens.contentMaxWidth),
          child: SizedBox.expand(
            child: Semantics(
              key: ValueKey<String>(
                'workbench-desktop-focus-${data.initialFocusTarget}',
              ),
              container: true,
              label: data.destinationLabel(data.activeDestination),
              explicitChildNodes: true,
              child: data.components.panel(
                context,
                key: const ValueKey<String>(
                  'workbench-desktop-workspace-surface',
                ),
                emphasized: true,
                child: data.destination,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

EdgeInsets _boundedOuterInsets({
  required BoxConstraints constraints,
  required LayoutEnvironment environment,
  required double base,
}) {
  final width = constraints.maxWidth.isFinite
      ? constraints.maxWidth
      : environment.width;
  final height = constraints.maxHeight.isFinite
      ? constraints.maxHeight
      : environment.height;
  final left = math.min(environment.safeInsets.left + base, width * 0.45);
  final right = math.min(
    environment.safeInsets.right + base,
    math.max(0.0, width - left - 1),
  );
  final top = math.min(environment.safeInsets.top + base, height * 0.45);
  final requestedBottom =
      environment.safeInsets.bottom + environment.keyboardInset + base;
  final bottom = math.min(requestedBottom, math.max(0.0, height - top - 1));
  return EdgeInsets.fromLTRB(left, top, right, bottom);
}

IconData _destinationIcon(ClientSection destination) => switch (destination) {
  ClientSection.controlPanel => Icons.home_rounded,
  ClientSection.agents => Icons.hub_rounded,
  ClientSection.feed => Icons.dynamic_feed_rounded,
  ClientSection.monitoring => Icons.insights_rounded,
  ClientSection.mcpPlugins => Icons.extension_rounded,
  ClientSection.skillHub => Icons.auto_awesome_rounded,
  ClientSection.localRuntime => Icons.memory_rounded,
  ClientSection.mobileRelay => Icons.devices_rounded,
  ClientSection.settings => Icons.tune_rounded,
};
