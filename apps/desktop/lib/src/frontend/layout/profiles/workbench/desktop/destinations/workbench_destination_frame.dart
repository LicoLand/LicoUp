import 'package:flutter/material.dart';

import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/layout_visual_tokens.dart';
import 'package:flutter_client/src/frontend/layout/profiles/workbench/desktop/components/workbench_desktop_component_kit.dart';

enum WorkbenchDesktopDestinationTreatment {
  overview,
  collaboration,
  analytics,
  extensions,
  runtime,
  relay,
  preferences,
}

void validateWorkbenchDesktopDestination(
  LayoutDestinationBuildContext data,
  ClientSection expected,
) {
  if (data.destination != expected ||
      data.environment.surface != LayoutRuntimeSurface.desktop) {
    throw const FormatException('workbench_desktop_destination_invalid');
  }
}

/// Adds only workbench presentation chrome around parent-owned feature content.
final class WorkbenchDesktopDestinationFrame extends StatelessWidget {
  const WorkbenchDesktopDestinationFrame({
    super.key,
    required this.data,
    required this.title,
    required this.icon,
    required this.treatment,
  });

  final LayoutDestinationBuildContext data;
  final String title;
  final IconData icon;
  final WorkbenchDesktopDestinationTreatment treatment;

  @override
  Widget build(BuildContext context) {
    final tokens = context.layoutVisualTokens;
    const components = WorkbenchDesktopComponentKit();
    final compactSpacing =
        data.environment.viewport == LayoutViewportClass.medium ||
        data.environment.textScale > 1.4;
    final spacing = tokens.spacingUnit * (compactSpacing ? 1.5 : 2.5);
    final content = data.content.buildDestination(context, data.destination);

    return Semantics(
      key: ValueKey<String>(
        'workbench-desktop-destination-${data.destination.name}',
      ),
      container: true,
      label: title,
      explicitChildNodes: true,
      child: ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerLowest,
        child: Padding(
          padding: EdgeInsets.all(spacing),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _DestinationHeading(
                title: title,
                icon: icon,
                treatment: treatment,
                components: components,
              ),
              SizedBox(height: spacing),
              Expanded(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth:
                          tokens.contentMaxWidth * treatment.contentWidthFactor,
                    ),
                    child: SizedBox.expand(
                      child: components.panel(
                        context,
                        key: ValueKey<String>(
                          'workbench-desktop-${data.destination.name}-content',
                        ),
                        child: content,
                      ),
                    ),
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

final class _DestinationHeading extends StatelessWidget {
  const _DestinationHeading({
    required this.title,
    required this.icon,
    required this.treatment,
    required this.components,
  });

  final String title;
  final IconData icon;
  final WorkbenchDesktopDestinationTreatment treatment;
  final WorkbenchDesktopComponentKit components;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return components.card(
      context,
      key: ValueKey<String>('workbench-desktop-${treatment.name}-heading'),
      child: Row(
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: treatment.containerColor(colors),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Padding(
              padding: const EdgeInsets.all(11),
              child: Icon(
                icon,
                size: 22,
                color: treatment.onContainerColor(colors),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.35,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

extension on WorkbenchDesktopDestinationTreatment {
  double get contentWidthFactor => switch (this) {
    WorkbenchDesktopDestinationTreatment.overview => 0.92,
    WorkbenchDesktopDestinationTreatment.collaboration => 1,
    WorkbenchDesktopDestinationTreatment.analytics => 0.94,
    WorkbenchDesktopDestinationTreatment.extensions => 0.96,
    WorkbenchDesktopDestinationTreatment.runtime => 0.9,
    WorkbenchDesktopDestinationTreatment.relay => 0.84,
    WorkbenchDesktopDestinationTreatment.preferences => 0.8,
  };

  Color containerColor(ColorScheme colors) => switch (this) {
    WorkbenchDesktopDestinationTreatment.overview => colors.primaryContainer,
    WorkbenchDesktopDestinationTreatment.collaboration =>
      colors.secondaryContainer,
    WorkbenchDesktopDestinationTreatment.analytics => colors.tertiaryContainer,
    WorkbenchDesktopDestinationTreatment.extensions => colors.primaryContainer,
    WorkbenchDesktopDestinationTreatment.runtime => colors.surfaceContainerHigh,
    WorkbenchDesktopDestinationTreatment.relay => colors.secondaryContainer,
    WorkbenchDesktopDestinationTreatment.preferences =>
      colors.surfaceContainerHighest,
  };

  Color onContainerColor(ColorScheme colors) => switch (this) {
    WorkbenchDesktopDestinationTreatment.overview => colors.onPrimaryContainer,
    WorkbenchDesktopDestinationTreatment.collaboration =>
      colors.onSecondaryContainer,
    WorkbenchDesktopDestinationTreatment.analytics =>
      colors.onTertiaryContainer,
    WorkbenchDesktopDestinationTreatment.extensions =>
      colors.onPrimaryContainer,
    WorkbenchDesktopDestinationTreatment.runtime => colors.onSurface,
    WorkbenchDesktopDestinationTreatment.relay => colors.onSecondaryContainer,
    WorkbenchDesktopDestinationTreatment.preferences => colors.onSurface,
  };
}
