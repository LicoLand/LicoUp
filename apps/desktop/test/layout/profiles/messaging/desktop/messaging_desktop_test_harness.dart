import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/l10n/lico_strings.dart';

import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_features.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_port.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/shell/layout_palette_projection.dart';
import 'package:licoup/src/frontend/layout/layout_scope.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/messaging_desktop.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

import '../../../fixtures/layout_chrome_fixture.dart';
import '../../../fixtures/layout_scoped_state_fixture.dart';

const Set<ClientSection> messagingDesktopExpectedDestinations = <ClientSection>{
  ClientSection.agents,
  ClientSection.monitoring,
  ClientSection.skillHub,
  ClientSection.pluginManagement,
  ClientSection.agentHub,
  ClientSection.mobileRelay,
  ClientSection.models,
  ClientSection.settings,
};

LayoutPalette messagingDesktopTestPalette(BuildContext context) {
  final colors = context.licoColors;
  return layoutPaletteFromColors(colors);
}

/// Records destination builds and selections for Messaging desktop shell
/// assertions.
final class MessagingDesktopHarness {
  final List<ClientSection> buildCalls = <ClientSection>[];
  final List<ClientSection> selections = <ClientSection>[];

  void selectDestination(ClientSection destination) {
    if (!messagingDesktopExpectedDestinations.contains(destination)) {
      throw const FormatException('messaging_test_destination_unknown');
    }
    selections.add(destination);
  }
}

final class MessagingDesktopFixtureContent
    implements LayoutDestinationContentPort {
  MessagingDesktopFixtureContent(this.harness);

  final MessagingDesktopHarness harness;

  @override
  Widget buildDestination(BuildContext context, ClientSection destination) {
    if (!messagingDesktopExpectedDestinations.contains(destination)) {
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

final class MessagingDesktopTestShell extends StatelessWidget {
  const MessagingDesktopTestShell({
    super.key,
    required this.environment,
    required this.activeDestination,
    required this.content,
    required this.harness,
    this.brightness = Brightness.dark,
    this.locale = const Locale('en'),
    this.chrome = const FixtureLayoutChromePort(),
  });

  final LayoutEnvironment environment;
  final ClientSection activeDestination;
  final MessagingDesktopFixtureContent content;
  final MessagingDesktopHarness harness;
  final Brightness brightness;
  final Locale locale;
  final LayoutChromePort chrome;

  @override
  Widget build(BuildContext context) {
    final bundle = messagingDesktopBundle;
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
      surface: LayoutRuntimeSurface.desktop,
      stateNamespaces: bundle.stateNamespaces,
      destination: activeDestination,
    );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: locale,
      supportedLocales: LicoStrings.supportedLocales,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      theme: baseTheme.copyWith(platform: TargetPlatform.macOS),
      home: Scaffold(
        body: SizedBox(
          width: environment.width,
          height: environment.height,
          child: MediaQuery(
            data: MediaQueryData(
              size: Size(environment.width, environment.height),
              textScaler: TextScaler.linear(environment.textScale),
              disableAnimations: environment.reducedMotion,
            ),
            child: Builder(
              builder: (paletteContext) => LayoutPaletteScope(
                palette: messagingDesktopTestPalette(paletteContext),
                child: LayoutChromeFeaturesScope(
                  features: const _FixtureChromeFeatures(),
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
      ),
    );
  }
}

LayoutEnvironment messagingDesktopEnvironment({
  required double width,
  required double height,
  double textScale = 1,
  bool reducedMotion = false,
}) => LayoutEnvironment.fromConstraints(
  surface: LayoutRuntimeSurface.desktop,
  width: width,
  height: height,
  textScale: textScale,
  reducedMotion: reducedMotion,
);

void configureMessagingTestView(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Minimal chrome-features stand-in so shell tests can assert the band's tab
/// and bell slots without pulling feature code across the profile boundary.
final class _FixtureChromeFeatures implements LayoutChromeFeatures {
  const _FixtureChromeFeatures();

  @override
  ValueNotifier<bool>? get auxChromePanelOpen => null;

  @override
  Widget buildConversationTabs(BuildContext context) => const SizedBox(
    key: Key('fixture-conversation-tabs'),
    width: 160,
    height: 30,
  );

  @override
  Widget buildNotificationBell(BuildContext context) => const SizedBox.square(
    key: Key('fixture-notification-bell'),
    dimension: 32,
  );
}
