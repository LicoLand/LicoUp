import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_scope.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/layout_visual_tokens.dart';
import 'package:flutter_client/src/frontend/layout/profiles/classic/mobile/classic_mobile_bundle.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

import '../../../fixtures/layout_chrome_fixture.dart';
import '../../../fixtures/layout_scoped_state_fixture.dart';

const Set<ClientSection> classicMobileDestinations = {
  ClientSection.agents,
  ClientSection.mobileRelay,
  ClientSection.settings,
};

LayoutEnvironment classicMobileEnvironment({
  double width = 390,
  double height = 600,
  double textScale = 1,
  LayoutInsets safeInsets = LayoutInsets.zero,
  double keyboardInset = 0,
  bool hasPointer = false,
  bool hasKeyboard = false,
  bool hasTouch = true,
  bool reducedMotion = false,
}) => LayoutEnvironment.fromConstraints(
  surface: LayoutRuntimeSurface.mobile,
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

String classicMobileDestinationLabel(ClientSection destination) =>
    switch (destination) {
      ClientSection.agents => 'Agents',
      ClientSection.mobileRelay => 'Mobile Relay',
      ClientSection.settings => 'Settings',
      _ => throw const FormatException(
        'classic_mobile_test_destination_unsupported',
      ),
    };

final class ClassicMobileFakeContentPort
    implements LayoutDestinationContentPort {
  final List<ClientSection> builtDestinations = [];
  final List<ClientSection> invokedActions = [];
  final List<Brightness> brightnesses = [];

  @override
  Widget buildDestination(BuildContext context, ClientSection destination) {
    if (!classicMobileDestinations.contains(destination)) {
      throw const FormatException(
        'classic_mobile_test_content_destination_unsupported',
      );
    }
    builtDestinations.add(destination);
    brightnesses.add(Theme.of(context).brightness);
    return ColoredBox(
      key: ValueKey<String>('classic-mobile-fake-content-${destination.name}'),
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: SingleChildScrollView(
              key: ValueKey<String>(
                'classic-mobile-fake-scroll-${destination.name}',
              ),
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Classic ${classicMobileDestinationLabel(destination)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Deterministic parent-owned content is forwarded through '
                    'the profile boundary without importing another layout.',
                  ),
                ],
              ),
            ),
          ),
          Container(
            key: ValueKey<String>(
              'classic-mobile-fake-composer-${destination.name}',
            ),
            height: 56,
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: Theme.of(context).dividerColor),
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Composer ${destination.name}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  key: ValueKey<String>(
                    'classic-mobile-fake-action-${destination.name}',
                  ),
                  tooltip:
                      'Invoke ${classicMobileDestinationLabel(destination)}',
                  onPressed: () => invokedActions.add(destination),
                  icon: const Icon(Icons.arrow_forward),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

final class ClassicMobileHarness {
  ClassicMobileHarness({
    this.activeDestination = ClientSection.agents,
    ClassicMobileFakeContentPort? content,
  }) : content = content ?? ClassicMobileFakeContentPort(),
       state = buildLayoutScopedStateFixture(
         profile: classicMobileBundle.profile,
         surface: LayoutRuntimeSurface.mobile,
         stateNamespaces: classicMobileBundle.stateNamespaces,
       );

  final ClientSection activeDestination;
  final ClassicMobileFakeContentPort content;
  final LayoutScopedState state;
  ClientSection? selectedDestination;

  LayoutDestinationBuildContext destinationData(
    LayoutEnvironment environment,
    ClientSection destination,
  ) => LayoutDestinationBuildContext(
    environment: environment,
    destination: destination,
    content: content,
    state: state,
  );

  Widget build(LayoutEnvironment environment) {
    final variant = classicMobileBundle.variants[environment.viewport]!;
    final destinationBuilder = variant.destinationBuilders[activeDestination]!;
    final destinations = variant.destinationBuilders.keys.toList()
      ..sort((left, right) => left.index.compareTo(right.index));
    return Builder(
      builder: (context) {
        final destination = destinationBuilder(
          context,
          destinationData(environment, activeDestination),
        );
        return variant.shellBuilder(
          context,
          LayoutShellBuildContext(
            environment: environment,
            activeDestination: activeDestination,
            availableDestinations: destinations,
            destination: destination,
            onSelectDestination: (value) => selectedDestination = value,
            destinationLabel: classicMobileDestinationLabel,
            components: classicMobileBundle.components,
            tokens: classicMobileBundle.tokens,
            initialFocusTarget: 'conversation-composer',
            chrome: const FixtureLayoutChromePort(),
          ),
        );
      },
    );
  }
}

Future<void> pumpClassicMobileHarness(
  WidgetTester tester, {
  required ClassicMobileHarness harness,
  required LayoutEnvironment environment,
  Brightness brightness = Brightness.light,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(environment.width, environment.height);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);

  final theme = buildLicoTheme(
    presetId: brightness == Brightness.dark
        ? 'lico-crystal'
        : 'geek-light-blue',
    platformBrightness: brightness,
  );
  await tester.pumpWidget(
    MaterialApp(
      restorationScopeId: 'classic-mobile-test',
      theme: theme.copyWith(
        extensions: [
          for (final extension in theme.extensions.values)
            if (extension is! LayoutVisualTokens) extension,
          classicMobileBundle.tokens,
        ],
      ),
      builder: (context, child) {
        final mediaQuery = MediaQuery.of(context);
        return MediaQuery(
          data: mediaQuery.copyWith(
            textScaler: TextScaler.linear(environment.textScale),
          ),
          child: child!,
        );
      },
      home: SizedBox.expand(child: harness.build(environment)),
    ),
  );
  await tester.pumpAndSettle();
}
