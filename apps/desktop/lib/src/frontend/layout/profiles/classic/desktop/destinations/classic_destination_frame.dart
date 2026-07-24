import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/layout_visual_tokens.dart';
import 'package:licoup/src/frontend/layout/profiles/classic/desktop/components/classic_desktop_component_kit.dart';

enum ClassicDesktopDestinationTreatment {
  overview,
  collaboration,
  analytics,
  extensions,
  runtime,
  relay,
  preferences,
}

void validateClassicDesktopDestination(
  LayoutDestinationBuildContext data,
  ClientSection expected,
) {
  if (data.destination != expected ||
      data.environment.surface != LayoutRuntimeSurface.desktop) {
    throw const FormatException('classic_desktop_destination_invalid');
  }
}

/// Adds only classic presentation chrome around parent-owned feature content.
final class ClassicDesktopDestinationFrame extends StatelessWidget {
  const ClassicDesktopDestinationFrame({
    super.key,
    required this.data,
    required this.title,
    required this.icon,
    required this.treatment,
  });

  final LayoutDestinationBuildContext data;
  final String title;
  final IconData icon;
  final ClassicDesktopDestinationTreatment treatment;

  @override
  Widget build(BuildContext context) {
    final tokens = context.layoutVisualTokens;
    const components = ClassicDesktopComponentKit();
    final compactSpacing =
        data.environment.viewport == LayoutViewportClass.medium ||
        data.environment.textScale > 1.4;
    final spacing = tokens.spacingUnit * (compactSpacing ? 1.5 : 2.5);
    final content = data.content.buildDestination(context, data.destination);

    return Semantics(
      key: ValueKey<String>(
        'classic-desktop-destination-${data.destination.name}',
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
                          'classic-desktop-${data.destination.name}-content',
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
  final ClassicDesktopDestinationTreatment treatment;
  final ClassicDesktopComponentKit components;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return components.card(
      context,
      key: ValueKey<String>('classic-desktop-${treatment.name}-heading'),
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

extension on ClassicDesktopDestinationTreatment {
  double get contentWidthFactor => switch (this) {
    ClassicDesktopDestinationTreatment.overview => 0.92,
    ClassicDesktopDestinationTreatment.collaboration => 1,
    ClassicDesktopDestinationTreatment.analytics => 0.94,
    ClassicDesktopDestinationTreatment.extensions => 0.96,
    ClassicDesktopDestinationTreatment.runtime => 0.9,
    ClassicDesktopDestinationTreatment.relay => 0.84,
    ClassicDesktopDestinationTreatment.preferences => 0.8,
  };

  Color containerColor(ColorScheme colors) => switch (this) {
    ClassicDesktopDestinationTreatment.overview => colors.primaryContainer,
    ClassicDesktopDestinationTreatment.collaboration =>
      colors.secondaryContainer,
    ClassicDesktopDestinationTreatment.analytics => colors.tertiaryContainer,
    ClassicDesktopDestinationTreatment.extensions => colors.primaryContainer,
    ClassicDesktopDestinationTreatment.runtime => colors.surfaceContainerHigh,
    ClassicDesktopDestinationTreatment.relay => colors.secondaryContainer,
    ClassicDesktopDestinationTreatment.preferences =>
      colors.surfaceContainerHighest,
  };

  Color onContainerColor(ColorScheme colors) => switch (this) {
    ClassicDesktopDestinationTreatment.overview => colors.onPrimaryContainer,
    ClassicDesktopDestinationTreatment.collaboration =>
      colors.onSecondaryContainer,
    ClassicDesktopDestinationTreatment.analytics => colors.onTertiaryContainer,
    ClassicDesktopDestinationTreatment.extensions => colors.onPrimaryContainer,
    ClassicDesktopDestinationTreatment.runtime => colors.onSurface,
    ClassicDesktopDestinationTreatment.relay => colors.onSecondaryContainer,
    ClassicDesktopDestinationTreatment.preferences => colors.onSurface,
  };
}
