import 'package:flutter/material.dart';

import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/workbench/desktop/workbench_desktop.dart';

const Set<ClientSection> workbenchDesktopCanonicalDestinations = {
  ClientSection.controlPanel,
  ClientSection.agents,
  ClientSection.monitoring,
  ClientSection.mcpPlugins,
  ClientSection.localRuntime,
  ClientSection.mobileRelay,
  ClientSection.settings,
};

LayoutEnvironment workbenchDesktopEnvironment({
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

final class WorkbenchDesktopShellHarness extends StatelessWidget {
  const WorkbenchDesktopShellHarness({
    super.key,
    required this.environment,
    required this.destination,
    this.activeDestination = ClientSection.agents,
    this.onSelectDestination,
    this.colorScheme,
  });

  final LayoutEnvironment environment;
  final Widget destination;
  final ClientSection activeDestination;
  final ValueChanged<ClientSection>? onSelectDestination;
  final ColorScheme? colorScheme;

  @override
  Widget build(BuildContext context) {
    final scheme =
        colorScheme ??
        ColorScheme.fromSeed(
          seedColor: const Color(0xff6650a4),
          brightness: Brightness.light,
        );
    final theme = ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
    ).copyWith(extensions: [workbenchDesktopBundle.tokens]);
    final variant = workbenchDesktopBundle.variants[environment.viewport]!;

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: const Locale('en'),
      theme: theme,
      builder: (context, child) {
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            textScaler: TextScaler.linear(environment.textScale),
            disableAnimations: environment.reducedMotion,
          ),
          child: child!,
        );
      },
      home: Builder(
        builder: (context) => SizedBox.expand(
          child: variant.shellBuilder(
            context,
            LayoutShellBuildContext(
              environment: environment,
              activeDestination: activeDestination,
              availableDestinations: workbenchDesktopCanonicalDestinations,
              destination: destination,
              onSelectDestination: onSelectDestination ?? (_) {},
              destinationLabel: (value) => value.name,
              components: workbenchDesktopBundle.components,
              tokens: workbenchDesktopBundle.tokens,
              initialFocusTarget: 'primary-landmark',
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
