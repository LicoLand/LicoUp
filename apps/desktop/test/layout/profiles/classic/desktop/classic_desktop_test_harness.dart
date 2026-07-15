import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_chrome_port.dart';
import 'package:flutter_client/src/frontend/layout/layout_palette.dart';
import 'package:flutter_client/src/frontend/layout/layout_scope.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/layout_visual_tokens.dart';
import 'package:flutter_client/src/frontend/layout/profiles/classic/desktop/classic_desktop.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

import '../../../fixtures/layout_chrome_fixture.dart';
import '../../../fixtures/layout_scoped_state_fixture.dart';

const Set<ClientSection> classicDesktopExpectedDestinations = {
  ClientSection.controlPanel,
  ClientSection.agents,
  ClientSection.monitoring,
  ClientSection.mcpPlugins,
  ClientSection.localRuntime,
  ClientSection.mobileRelay,
  ClientSection.settings,
};

const Map<ClientSection, String> classicDesktopTestLabels = {
  ClientSection.controlPanel: 'Home',
  ClientSection.agents: 'Agents',
  ClientSection.monitoring: 'Token Usage',
  ClientSection.mcpPlugins: 'Plugins & Skills',
  ClientSection.localRuntime: 'Runtime',
  ClientSection.mobileRelay: 'Mobile Relay',
  ClientSection.settings: 'Settings',
};

final class ClassicDesktopActionRecorder {
  final List<ClientSection> destinationSelections = [];
  final List<(ClientSection, String)> contentActions = [];

  void selectDestination(ClientSection destination) {
    _requireDestination(destination);
    destinationSelections.add(destination);
  }

  void invokeContentAction(ClientSection destination) {
    _requireDestination(destination);
    contentActions.add((destination, 'primary'));
  }

  static void _requireDestination(ClientSection destination) {
    if (!classicDesktopExpectedDestinations.contains(destination)) {
      throw const FormatException('classic_test_destination_unknown');
    }
  }
}

final class ClassicDesktopRecordingContentPort
    implements LayoutDestinationContentPort {
  ClassicDesktopRecordingContentPort(this.actions);

  final ClassicDesktopActionRecorder actions;
  final List<ClientSection> buildCalls = [];
  final List<Brightness> brightnesses = [];

  @override
  Widget buildDestination(BuildContext context, ClientSection destination) {
    if (!classicDesktopExpectedDestinations.contains(destination)) {
      throw const FormatException('classic_test_content_destination_unknown');
    }
    buildCalls.add(destination);
    brightnesses.add(Theme.of(context).brightness);
    final label = classicDesktopDestinationLabel(destination);
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: 'Content $label',
      child: ColoredBox(
        key: ValueKey<String>('classic-fake-content-${destination.name}'),
        color: Theme.of(context).colorScheme.surface,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  TextButton(
                    key: ValueKey<String>(
                      'classic-content-action-${destination.name}',
                    ),
                    onPressed: () => actions.invokeContentAction(destination),
                    child: const Text('RUN'),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      flex: 3,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerLow,
                          border: Border.all(
                            color: Theme.of(context).colorScheme.outlineVariant,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 2,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerHigh,
                          border: Border.all(
                            color: Theme.of(context).colorScheme.outlineVariant,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class ClassicDesktopTestHarness extends StatelessWidget {
  const ClassicDesktopTestHarness({
    super.key,
    required this.environment,
    required this.activeDestination,
    required this.content,
    required this.actions,
    this.brightness = Brightness.light,
    this.chrome = const FixtureLayoutChromePort(),
  });

  final LayoutEnvironment environment;
  final ClientSection activeDestination;
  final ClassicDesktopRecordingContentPort content;
  final ClassicDesktopActionRecorder actions;
  final Brightness brightness;
  final LayoutChromePort chrome;

  @override
  Widget build(BuildContext context) {
    final bundle = classicDesktopBundle;
    final variant = bundle.variants[environment.viewport];
    if (variant == null) {
      throw const FormatException('classic_test_viewport_unregistered');
    }
    final destinationBuilder = variant.destinationBuilders[activeDestination];
    if (destinationBuilder == null) {
      throw const FormatException('classic_test_destination_unregistered');
    }
    final destinations = variant.destinationBuilders.keys.toList()
      ..sort((left, right) => left.index.compareTo(right.index));
    final baseTheme = buildLicoTheme(
      presetId: brightness == Brightness.dark
          ? 'lico-crystal'
          : 'geek-light-blue',
      platformBrightness: brightness,
    );
    final theme = baseTheme.copyWith(
      platform: TargetPlatform.macOS,
      extensions: [
        for (final extension in baseTheme.extensions.values)
          if (extension is! LayoutVisualTokens) extension,
        bundle.tokens,
      ],
    );
    final scopedState = buildLayoutScopedStateFixture(
      profile: bundle.profile,
      surface: LayoutRuntimeSurface.desktop,
      stateNamespaces: bundle.stateNamespaces,
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      builder: (context, child) {
        final colors = context.licoColors;
        return LayoutPaletteScope(
          palette: LayoutPalette(
            background: colors.background,
            surface: colors.surface,
            surfaceLow: colors.surfaceLow,
            surfaceHigh: colors.surfaceHigh,
            surfaceHighest: colors.surfaceHighest,
            line: colors.line,
            text: colors.text,
            textMuted: colors.textMuted,
            primary: colors.primary,
            primaryStrong: colors.primaryStrong,
            primaryFixed: colors.primaryFixed,
            textOnPrimary: colors.textOnPrimary,
            info: colors.info,
            infoMuted: colors.infoMuted,
            success: colors.success,
            warning: colors.warning,
            error: colors.error,
          ),
          child: child!,
        );
      },
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            key: const ValueKey<String>('classic-desktop-test-viewport'),
            width: environment.width,
            height: environment.height,
            child: MediaQuery(
              data: MediaQueryData(
                size: Size(environment.width, environment.height),
                padding: EdgeInsets.fromLTRB(
                  environment.safeInsets.left,
                  environment.safeInsets.top,
                  environment.safeInsets.right,
                  environment.safeInsets.bottom,
                ),
                viewInsets: EdgeInsets.only(bottom: environment.keyboardInset),
                textScaler: TextScaler.linear(environment.textScale),
                disableAnimations: environment.reducedMotion,
              ),
              child: LayoutScope(
                profileId: bundle.profile.id,
                environment: environment,
                restorationNamespace: bundle.restorationNamespace,
                tokens: bundle.tokens,
                state: scopedState,
                child: Builder(
                  builder: (profileContext) {
                    final destination = destinationBuilder(
                      profileContext,
                      LayoutDestinationBuildContext(
                        environment: environment,
                        destination: activeDestination,
                        content: content,
                        state: scopedState,
                      ),
                    );
                    return variant.shellBuilder(
                      profileContext,
                      LayoutShellBuildContext(
                        environment: environment,
                        activeDestination: activeDestination,
                        availableDestinations: destinations,
                        destination: destination,
                        onSelectDestination: actions.selectDestination,
                        destinationLabel: classicDesktopDestinationLabel,
                        components: bundle.components,
                        tokens: bundle.tokens,
                        initialFocusTarget: 'primary-content',
                        chrome: chrome,
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

LayoutScopedState buildClassicDesktopScopedStateForTest() =>
    buildLayoutScopedStateFixture(
      profile: classicDesktopBundle.profile,
      surface: LayoutRuntimeSurface.desktop,
      stateNamespaces: classicDesktopBundle.stateNamespaces,
    );

LayoutDestinationBuildContext buildClassicDesktopDestinationDataForTest({
  required LayoutEnvironment environment,
  required ClientSection destination,
  required LayoutDestinationContentPort content,
  required LayoutScopedState state,
}) => LayoutDestinationBuildContext(
  environment: environment,
  destination: destination,
  content: content,
  state: state,
);

String classicDesktopDestinationLabel(ClientSection destination) {
  final label = classicDesktopTestLabels[destination];
  if (label == null) {
    throw const FormatException('classic_test_destination_label_unknown');
  }
  return label;
}

LayoutEnvironment classicDesktopEnvironment({
  required double width,
  required double height,
  double textScale = 1,
  LayoutInsets safeInsets = LayoutInsets.zero,
  double keyboardInset = 0,
  bool hasPointer = false,
  bool hasKeyboard = false,
  bool hasTouch = false,
  bool reducedMotion = false,
}) => LayoutEnvironment.fromConstraints(
  surface: LayoutRuntimeSurface.desktop,
  width: width,
  height: height,
  textScale: textScale,
  safeInsets: safeInsets,
  keyboardInset: keyboardInset,
  hasPointer: hasPointer,
  hasKeyboard: hasKeyboard,
  hasTouch: hasTouch,
  reducedMotion: reducedMotion,
);

void configureClassicDesktopTestView(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}
