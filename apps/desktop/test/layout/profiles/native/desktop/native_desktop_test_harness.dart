import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_scope.dart';
import 'package:flutter_client/src/frontend/layout/layout_chrome_port.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/layout_visual_tokens.dart';
import 'package:flutter_client/src/frontend/layout/profiles/native/desktop/native_desktop.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

import '../../../fixtures/layout_chrome_fixture.dart';
import '../../../fixtures/layout_scoped_state_fixture.dart';
import 'native_desktop_palette_fixture.dart';

const Set<ClientSection> nativeDesktopExpectedDestinations = <ClientSection>{
  ClientSection.agents,
  ClientSection.monitoring,
  ClientSection.skillHub,
  ClientSection.mobileRelay,
  ClientSection.settings,
};

const Map<ClientSection, String> nativeDesktopTestLabels =
    <ClientSection, String>{
      ClientSection.agents: 'Agents',
      ClientSection.monitoring: 'Monitoring',
      ClientSection.skillHub: 'Skill Hub',
      ClientSection.mobileRelay: 'Mobile Relay',
      ClientSection.settings: 'Settings',
    };

final class NativeActionRecorder {
  final List<ClientSection> destinationSelections = <ClientSection>[];
  final List<(ClientSection, String)> contentActions =
      <(ClientSection, String)>[];

  void selectDestination(ClientSection destination) {
    _requireDesktopDestination(destination);
    destinationSelections.add(destination);
  }

  void invokeContentAction(ClientSection destination, String action) {
    _requireDesktopDestination(destination);
    if (action != 'primary') {
      throw const FormatException('native_test_action_unknown');
    }
    contentActions.add((destination, action));
  }

  static void _requireDesktopDestination(ClientSection destination) {
    if (!nativeDesktopExpectedDestinations.contains(destination)) {
      throw const FormatException('native_test_destination_unknown');
    }
  }
}

final class NativeRecordingContentPort implements LayoutDestinationContentPort {
  NativeRecordingContentPort(this.actions);

  final NativeActionRecorder actions;
  final List<ClientSection> buildCalls = <ClientSection>[];
  final List<Brightness> brightnesses = <Brightness>[];

  @override
  Widget buildDestination(BuildContext context, ClientSection destination) {
    if (!nativeDesktopExpectedDestinations.contains(destination)) {
      throw const FormatException('native_test_content_destination_unknown');
    }
    buildCalls.add(destination);
    brightnesses.add(Theme.of(context).brightness);
    return _NativeFakeDestinationSurface(
      destination: destination,
      onPrimaryAction: () =>
          actions.invokeContentAction(destination, 'primary'),
    );
  }
}

final class NativeDesktopTestHarness extends StatelessWidget {
  const NativeDesktopTestHarness({
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
  final NativeRecordingContentPort content;
  final NativeActionRecorder actions;
  final Brightness brightness;
  final LayoutChromePort chrome;

  @override
  Widget build(BuildContext context) {
    final bundle = nativeDesktopBundle;
    final variant = bundle.variants[environment.viewport];
    if (variant == null) {
      throw const FormatException('native_test_viewport_unregistered');
    }
    final destinationBuilder = variant.destinationBuilders[activeDestination];
    if (destinationBuilder == null) {
      throw const FormatException('native_test_destination_unregistered');
    }
    final destinations = variant.destinationBuilders.keys.toList()
      ..sort((left, right) => left.index.compareTo(right.index));
    final baseTheme = buildLicoTheme(
      presetId: brightness == Brightness.dark
          ? 'lico-crystal'
          : 'geek-light-blue',
      platformBrightness: brightness,
    );
    final extensions = [
      for (final extension in baseTheme.extensions.values)
        if (extension is! LayoutVisualTokens) extension,
      bundle.tokens,
    ];
    final theme = baseTheme.copyWith(
      platform: TargetPlatform.macOS,
      extensions: extensions,
    );
    final scopedState = buildLayoutScopedStateFixture(
      profile: bundle.profile,
      surface: LayoutRuntimeSurface.desktop,
      stateNamespaces: bundle.stateNamespaces,
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      themeMode: ThemeMode.light,
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            key: const ValueKey<String>('native-desktop-test-viewport'),
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
              child: Builder(
                builder: (paletteContext) => withNativeDesktopTestPalette(
                  paletteContext,
                  LayoutScope(
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
                            destinationLabel: nativeDesktopDestinationLabel,
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
        ),
      ),
    );
  }
}

String nativeDesktopDestinationLabel(ClientSection destination) {
  final label = nativeDesktopTestLabels[destination];
  if (label == null) {
    throw const FormatException('native_test_destination_label_unknown');
  }
  return label;
}

LayoutEnvironment nativeDesktopEnvironment({
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

void configureNativeTestView(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

final class _NativeFakeDestinationSurface extends StatelessWidget {
  const _NativeFakeDestinationSurface({
    required this.destination,
    required this.onPrimaryAction,
  });

  final ClientSection destination;
  final VoidCallback onPrimaryAction;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final label = nativeDesktopDestinationLabel(destination);
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: 'Content $label',
      child: ColoredBox(
        key: ValueKey<String>('native-fake-content-${destination.name}'),
        color: colors.background,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(width: 3, height: 24, color: colors.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      label,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  TextButton(
                    key: ValueKey<String>(
                      'native-content-action-${destination.name}',
                    ),
                    onPressed: onPrimaryAction,
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
                          color: colors.surfaceLow,
                          border: Border.all(color: colors.line),
                        ),
                        child: const SizedBox.expand(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 2,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: colors.surface,
                                border: Border.all(color: colors.line),
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Expanded(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: colors.surface,
                                border: Border.all(color: colors.line),
                              ),
                            ),
                          ),
                        ],
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
