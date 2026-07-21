import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_scope.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/layout_visual_tokens.dart';
import 'package:flutter_client/src/frontend/layout/profiles/native/mobile/native_mobile_bundle.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

import '../../../fixtures/layout_chrome_fixture.dart';
import '../../../fixtures/layout_scoped_state_fixture.dart';
import 'native_mobile_palette_fixture.dart';

const nativeMobileDestinations = <ClientSection>{
  ClientSection.agents,
  ClientSection.mobileRelay,
  ClientSection.settings,
};

LayoutEnvironment nativeMobileEnvironment({
  double width = 390,
  double height = 600,
  double textScale = 1,
  LayoutInsets safeInsets = LayoutInsets.zero,
  double keyboardInset = 0,
  bool hasPointer = false,
  bool hasKeyboard = false,
  bool hasTouch = true,
  bool reducedMotion = false,
}) {
  return LayoutEnvironment.fromConstraints(
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
}

String nativeDestinationLabel(ClientSection destination) {
  return switch (destination) {
    ClientSection.agents => 'Agents',
    ClientSection.mobileRelay => 'Mobile Relay',
    ClientSection.settings => 'Settings',
    _ => throw const FormatException(
      'native_mobile_test_destination_unsupported',
    ),
  };
}

final class NativeMobileFakeContentPort
    implements LayoutDestinationContentPort {
  final List<ClientSection> builtDestinations = [];
  final List<ClientSection> invokedActions = [];

  @override
  Widget buildDestination(BuildContext context, ClientSection destination) {
    builtDestinations.add(destination);
    return ColoredBox(
      key: ValueKey('native-fake-content-${destination.name}'),
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: SingleChildScrollView(
              key: ValueKey('native-fake-scroll-${destination.name}'),
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Native ${nativeDestinationLabel(destination)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Deterministic parent-owned content remains outside the '
                    'renderer and is forwarded through the narrow content port.',
                  ),
                ],
              ),
            ),
          ),
          Container(
            key: ValueKey('native-fake-composer-${destination.name}'),
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
                  key: ValueKey('native-fake-action-${destination.name}'),
                  tooltip: 'Invoke ${nativeDestinationLabel(destination)}',
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

final class NativeMobileHarness {
  NativeMobileHarness({
    this.activeDestination = ClientSection.agents,
    NativeMobileFakeContentPort? content,
  }) : content = content ?? NativeMobileFakeContentPort(),
       state = buildLayoutScopedStateFixture(
         profile: nativeMobileBundle.profile,
         surface: LayoutRuntimeSurface.mobile,
         stateNamespaces: nativeMobileBundle.stateNamespaces,
       );

  final ClientSection activeDestination;
  final NativeMobileFakeContentPort content;
  final LayoutScopedState state;
  ClientSection? selectedDestination;

  LayoutDestinationBuildContext destinationData(
    LayoutEnvironment environment,
    ClientSection destination,
  ) {
    return LayoutDestinationBuildContext(
      environment: environment,
      destination: destination,
      content: content,
      state: state,
    );
  }

  Widget build(LayoutEnvironment environment) {
    final variant = nativeMobileBundle.variants[environment.viewport]!;
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
            destinationLabel: nativeDestinationLabel,
            components: nativeMobileBundle.components,
            tokens: nativeMobileBundle.tokens,
            initialFocusTarget: 'conversation-composer',
            chrome: const FixtureLayoutChromePort(),
          ),
        );
      },
    );
  }
}

Future<void> pumpNativeMobileHarness(
  WidgetTester tester, {
  required NativeMobileHarness harness,
  required LayoutEnvironment environment,
  Brightness brightness = Brightness.light,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(environment.width, environment.height);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);

  final theme = buildLicoTheme(platformBrightness: brightness);
  await tester.pumpWidget(
    MaterialApp(
      restorationScopeId: 'native-mobile-test',
      theme: theme.copyWith(
        extensions: [
          ...theme.extensions.values.where(
            (extension) => extension is! LayoutVisualTokens,
          ),
          nativeMobileBundle.tokens,
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
      home: Builder(
        builder: (context) => withNativeMobileTestPalette(
          context,
          SizedBox.expand(child: harness.build(environment)),
        ),
      ),
    ),
  );
  await tester.pump();
}
