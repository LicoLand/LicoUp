import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_port.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/shell/layout_palette_projection.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/dashboard_desktop.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

import '../../../fixtures/layout_chrome_fixture.dart';

const Set<ClientSection> dashboardDesktopCanonicalDestinations = {
  ClientSection.agents,
  ClientSection.monitoring,
  ClientSection.skillHub,
  ClientSection.pluginManagement,
  ClientSection.mobileRelay,
  ClientSection.models,
  ClientSection.settings,
};

LayoutEnvironment dashboardDesktopEnvironment({
  required double width,
  double height = 760,
  double textScale = 1,
  bool reducedMotion = false,
  bool hasKeyboard = true,
  bool hasPointer = true,
}) => LayoutEnvironment.fromConstraints(
  surface: LayoutRuntimeSurface.desktop,
  width: width,
  height: height,
  textScale: textScale,
  hasKeyboard: hasKeyboard,
  hasPointer: hasPointer,
  reducedMotion: reducedMotion,
);

final class DashboardDesktopShellHarness extends StatelessWidget {
  const DashboardDesktopShellHarness({
    super.key,
    required this.environment,
    required this.destination,
    this.activeDestination = ClientSection.agents,
    this.onSelectDestination,
    this.colorScheme,
    this.chrome = const FixtureLayoutChromePort(),
  });

  final LayoutEnvironment environment;
  final Widget destination;
  final ClientSection activeDestination;
  final ValueChanged<ClientSection>? onSelectDestination;
  final ColorScheme? colorScheme;
  final LayoutChromePort chrome;

  @override
  Widget build(BuildContext context) {
    final base = buildLicoTheme(
      presetId: 'geek-light-blue',
      platformBrightness: Brightness.light,
    );
    final theme = base.copyWith(
      platform: TargetPlatform.macOS,
      colorScheme: colorScheme ?? base.colorScheme,
      extensions: [...base.extensions.values, dashboardDesktopBundle.tokens],
    );
    final variant = dashboardDesktopBundle.variants[environment.viewport]!;

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: const Locale('en'),
      theme: theme,
      builder: (context, child) {
        final media = MediaQuery.of(context);
        final colors = context.licoColors;
        return LayoutPaletteScope(
          palette: layoutPaletteFromColors(colors),
          child: MediaQuery(
            data: media.copyWith(
              textScaler: TextScaler.linear(environment.textScale),
              disableAnimations: environment.reducedMotion,
            ),
            child: child!,
          ),
        );
      },
      home: Builder(
        builder: (context) => SizedBox.expand(
          child: variant.shellBuilder(
            context,
            LayoutShellBuildContext(
              environment: environment,
              activeDestination: activeDestination,
              availableDestinations: dashboardDesktopCanonicalDestinations,
              destination: destination,
              onSelectDestination: onSelectDestination ?? (_) {},
              destinationLabel: (value) => value.name,
              components: dashboardDesktopBundle.components,
              tokens: dashboardDesktopBundle.tokens,
              initialFocusTarget: 'primary-landmark',
              chrome: chrome,
            ),
          ),
        ),
      ),
    );
  }
}

final class DestinationBuildCounter {
  int builds = 0;
}

final class CountingDestination extends StatelessWidget {
  const CountingDestination({
    super.key,
    required this.counter,
    required this.label,
  });

  final DestinationBuildCounter counter;
  final String label;

  @override
  Widget build(BuildContext context) {
    counter.builds += 1;
    return Center(child: Text(label, key: const Key('passed-destination')));
  }
}
