import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_port.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/shell/layout_palette_projection.dart';
import 'package:licoup/src/frontend/layout/layout_scope.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/mobile/messaging_mobile_bundle.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

import '../../../fixtures/layout_chrome_fixture.dart';
import '../../../fixtures/layout_scoped_state_fixture.dart';

const Set<ClientSection> messagingMobileExpectedDestinations = <ClientSection>{
  ClientSection.agents,
  ClientSection.mobileRelay,
  ClientSection.settings,
};

LayoutPalette messagingMobileTestPalette(BuildContext context) {
  final colors = context.licoColors;
  return layoutPaletteFromColors(colors);
}

/// Records destination builds and selections for Messaging mobile shell
/// assertions.
final class MessagingMobileHarness {
  final List<ClientSection> buildCalls = <ClientSection>[];
  final List<ClientSection> selections = <ClientSection>[];

  void selectDestination(ClientSection destination) {
    if (!messagingMobileExpectedDestinations.contains(destination)) {
      throw const FormatException('messaging_test_destination_unknown');
    }
    selections.add(destination);
  }
}

final class MessagingMobileFixtureContent
    implements LayoutDestinationContentPort {
  MessagingMobileFixtureContent(this.harness);

  final MessagingMobileHarness harness;

  @override
  Widget buildDestination(BuildContext context, ClientSection destination) {
    if (!messagingMobileExpectedDestinations.contains(destination)) {
      throw const FormatException('messaging_test_content_destination_unknown');
    }
    harness.buildCalls.add(destination);
    return ColoredBox(
      key: ValueKey<String>('messaging-fake-content-${destination.name}'),
      color: Colors.transparent,
      child: Center(child: Text('Content ${destination.name}')),
    );
  }
}

final class MessagingMobileTestShell extends StatelessWidget {
  const MessagingMobileTestShell({
    super.key,
    required this.environment,
    required this.activeDestination,
    required this.content,
    required this.harness,
    this.brightness = Brightness.dark,
    this.chrome = const FixtureLayoutChromePort(),
  });

  final LayoutEnvironment environment;
  final ClientSection activeDestination;
  final MessagingMobileFixtureContent content;
  final MessagingMobileHarness harness;
  final Brightness brightness;
  final LayoutChromePort chrome;

  @override
  Widget build(BuildContext context) {
    final bundle = messagingMobileBundle;
    final variant = bundle.variants[environment.viewport];
    if (variant == null) {
      throw const FormatException('messaging_test_viewport_unregistered');
    }
    final destinationBuilder = variant.destinationBuilders[activeDestination];
    if (destinationBuilder == null) {
      throw const FormatException('messaging_test_destination_unregistered');
    }
    final destinations = variant.destinationBuilders.keys.toList()
      ..sort((left, right) => left.index.compareTo(right.index));
    final baseTheme = buildLicoTheme(
      presetId: brightness == Brightness.dark
          ? 'lico-crystal'
          : 'geek-light-blue',
      platformBrightness: brightness,
    );
    final scopedState = buildLayoutScopedStateFixture(
      profile: bundle.profile,
      surface: LayoutRuntimeSurface.mobile,
      stateNamespaces: bundle.stateNamespaces,
    );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: baseTheme.copyWith(platform: TargetPlatform.iOS),
      home: Scaffold(
        body: SizedBox(
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
              textScaler: TextScaler.linear(environment.textScale),
              disableAnimations: environment.reducedMotion,
            ),
            child: Builder(
              builder: (paletteContext) => LayoutPaletteScope(
                palette: messagingMobileTestPalette(paletteContext),
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
                          onSelectDestination: harness.selectDestination,
                          destinationLabel: (value) => value.name,
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
    );
  }
}

LayoutEnvironment messagingMobileEnvironment({
  required double width,
  required double height,
  double textScale = 1,
  bool hasTouch = true,
  bool reducedMotion = false,
}) => LayoutEnvironment.fromConstraints(
  surface: LayoutRuntimeSurface.mobile,
  width: width,
  height: height,
  textScale: textScale,
  hasTouch: hasTouch,
  reducedMotion: reducedMotion,
);

void configureMessagingMobileTestView(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}
