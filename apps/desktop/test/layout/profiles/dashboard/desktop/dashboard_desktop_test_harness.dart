import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/l10n/lico_strings.dart';

import 'package:licoup/src/contracts/presentation/dashboard_feature_order.dart';
import 'package:licoup/src/frontend/shared/dashboard_feature_order_store.dart';
import 'package:licoup/src/contracts/presentation/built_in_layout_spec.dart';
import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_style.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_features.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_port.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/shared/layout_palette_projection.dart';
import 'package:licoup/src/frontend/layout/layout_scope.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/dashboard_desktop.dart';
import 'package:licoup/src/frontend/shared/messaging/messaging_sidebar_navigation.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

import '../../../fixtures/layout_chrome_features_fixture.dart';
import '../../../fixtures/layout_chrome_fixture.dart';
import '../../../fixtures/layout_scoped_state_fixture.dart';

const Set<ClientSection> dashboardDesktopExpectedDestinations = <ClientSection>{
  ClientSection.agents,
  ClientSection.monitoring,
  ClientSection.skillHub,
  ClientSection.pluginManagement,
  ClientSection.agentHub,
  ClientSection.devices,
  ClientSection.models,
  ClientSection.settings,
};

LayoutPalette dashboardDesktopTestPalette(BuildContext context) {
  final colors = context.licoColors;
  return layoutPaletteFromColors(colors);
}

/// Records destination builds and selections for Dashboard desktop shell
/// assertions.
final class DashboardDesktopHarness {
  final List<ClientSection> buildCalls = <ClientSection>[];
  final List<ClientSection> selections = <ClientSection>[];

  void selectDestination(ClientSection destination) {
    if (!dashboardDesktopExpectedDestinations.contains(destination)) {
      throw const FormatException('dashboard_test_destination_unknown');
    }
    selections.add(destination);
  }
}

final class DashboardDesktopFixtureContent
    implements LayoutDestinationContentPort {
  DashboardDesktopFixtureContent(this.harness);

  final DashboardDesktopHarness harness;

  @override
  Widget buildDestination(BuildContext context, ClientSection destination) {
    if (!dashboardDesktopExpectedDestinations.contains(destination)) {
      throw const FormatException('dashboard_test_content_destination_unknown');
    }
    harness.buildCalls.add(destination);
    return ColoredBox(
      key: ValueKey<String>('dashboard-fake-content-${destination.name}'),
      color: Colors.transparent,
      child: Center(child: Text('Content ${destination.name}')),
    );
  }
}

final class DashboardDesktopTestShell extends StatelessWidget {
  const DashboardDesktopTestShell({
    super.key,
    required this.environment,
    required this.activeDestination,
    required this.content,
    required this.harness,
    this.brightness = Brightness.dark,
    this.locale = const Locale('en'),
    this.chrome = const FixtureLayoutChromePort(),
    this.chromeFeatures,
    this.style,
  });

  final LayoutEnvironment environment;
  final ClientSection activeDestination;
  final LayoutDestinationContentPort content;
  final DashboardDesktopHarness harness;
  final Brightness brightness;
  final Locale locale;
  final LayoutChromePort chrome;

  /// Feature-chrome stand-in for the shell: collaboration state drives the
  /// rail badge. Defaults to the plain fixture.
  final LayoutChromeFeatures? chromeFeatures;

  /// The column arrangement under test. Existing baselines omit it, pinning
  /// them to `card`; plain coverage passes it explicitly.
  final LayoutStyleId? style;

  @override
  Widget build(BuildContext context) {
    final bundle = dashboardDesktopBundle;
    final variant = bundle.variants[environment.viewport];
    if (variant == null) {
      throw const FormatException('dashboard_test_viewport_unregistered');
    }
    final destinationBuilder = variant.destinationBuilders[activeDestination];
    if (destinationBuilder == null) {
      throw const FormatException('dashboard_test_destination_unregistered');
    }
    final destinations = variant.destinationBuilders.keys.toList()
      ..sort((left, right) => left.index.compareTo(right.index));
    final baseTheme = buildLicoTheme(
      presetId: brightness == Brightness.dark
          ? 'lico-starlit-gold'
          : 'lico-taro-waffle',
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
                palette: dashboardDesktopTestPalette(paletteContext),
                child: LayoutChromeFeaturesScope(
                  features: chromeFeatures ?? FixtureLayoutChromeFeatures(),
                  child: MessagingFeatureOrderScope(
                    orderStore: const _InMemoryFeatureOrderStore(),
                    child: LayoutScope(
                      profileId: bundle.profile.id,
                      environment: environment,
                      restorationNamespace: bundle.restorationNamespace,
                      tokens: bundle.tokens,
                      state: scopedState,
                      child: Builder(
                        builder: (profileContext) {
                          final resolvedStyle =
                              style ?? BuiltInLayoutSpec.dashboardCardStyleId;
                          final destination = destinationBuilder(
                            profileContext,
                            LayoutDestinationBuildContext(
                              environment: environment,
                              destination: activeDestination,
                              content: content,
                              state: scopedState,
                              style: resolvedStyle,
                            ),
                          );
                          return variant.shellBuilder(
                            profileContext,
                            LayoutShellBuildContext(
                              environment: environment,
                              activeDestination: activeDestination,
                              availableDestinations: destinations,
                              destination: destination,
                              content: content,
                              onSelectDestination: harness.selectDestination,
                              destinationLabel: (value) => value.name,
                              components: bundle.components,
                              tokens: bundle.tokens,
                              initialFocusTarget: 'primary-content',
                              chrome: chrome,
                              style: resolvedStyle,
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
      ),
    );
  }
}

LayoutEnvironment dashboardDesktopEnvironment({
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

void configureDashboardTestView(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// In-memory 功能 order store for shell tests: starts from the frozen
/// default and keeps writes in memory so the host's real order file is never
/// read.
final class _InMemoryFeatureOrderStore extends DashboardFeatureOrderStore {
  const _InMemoryFeatureOrderStore();

  @override
  Future<List<String>> load(Object portableData) async =>
      DashboardFeatureOrder.defaultOrder;

  @override
  Future<void> save(Object portableData, List<String> order) async {}
}
