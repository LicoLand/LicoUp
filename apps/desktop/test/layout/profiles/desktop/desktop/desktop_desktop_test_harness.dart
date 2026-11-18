import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_features.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_port.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/layout_scope.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/desktop_desktop.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/dock/desktop_dock_model.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/shell/desktop_desktop_shell.dart';
import 'package:licoup/src/frontend/shared/layout_palette_projection.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

import '../../../fixtures/desktop_dock_store_fixture.dart';
import '../../../fixtures/layout_chrome_features_fixture.dart';
import '../../../fixtures/layout_scoped_state_fixture.dart';

const Set<ClientSection> desktopDesktopExpectedDestinations = <ClientSection>{
  ClientSection.agents,
  ClientSection.monitoring,
  ClientSection.skillHub,
  ClientSection.pluginManagement,
  ClientSection.agentHub,
  ClientSection.devices,
  ClientSection.models,
  ClientSection.settings,
};

/// Records destination builds, selections, and chrome usage for Desktop
/// desktop shell assertions.
final class DesktopDesktopHarness {
  final List<ClientSection> buildCalls = <ClientSection>[];
  final List<ClientSection> selections = <ClientSection>[];
  int searchOpens = 0;
  LayoutScopedState? scopedState;
  final FixtureLayoutChromeFeatures features = FixtureLayoutChromeFeatures();

  void selectDestination(ClientSection destination) {
    if (!desktopDesktopExpectedDestinations.contains(destination)) {
      throw const FormatException('desktop_test_destination_unknown');
    }
    selections.add(destination);
  }
}

final class DesktopDesktopFixtureContent
    implements LayoutDestinationContentPort {
  DesktopDesktopFixtureContent(this.harness);

  final DesktopDesktopHarness harness;

  @override
  Widget buildDestination(BuildContext context, ClientSection destination) {
    if (!desktopDesktopExpectedDestinations.contains(destination)) {
      throw const FormatException('desktop_test_content_destination_unknown');
    }
    harness.buildCalls.add(destination);
    return ColoredBox(
      key: ValueKey<String>('desktop-fake-content-${destination.name}'),
      color: Colors.transparent,
      child: Center(child: Text('Content ${destination.name}')),
    );
  }
}

final class DesktopDesktopRecordingChromePort implements LayoutChromePort {
  DesktopDesktopRecordingChromePort(this.harness);

  final DesktopDesktopHarness harness;

  @override
  LayoutChromeSnapshot get value => const LayoutChromeSnapshot.empty();

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}

  @override
  Future<void> openGlobalSearch(BuildContext context) async {
    harness.searchOpens += 1;
  }
}

/// Builds a dock model backed by a throwaway directory, registered for
/// cleanup. The platform-backed store and data root come from the fixture
/// bridge because owned profile tests never import platform code directly.
DesktopDockModel buildDesktopTestDockModel() {
  final directory = Directory.systemTemp.createTempSync(
    'desktop_dock_controller_test',
  );
  addTearDown(() {
    if (directory.existsSync()) {
      directory.deleteSync(recursive: true);
    }
  });
  return DesktopDockModel(
    store: createDesktopDockLayoutStore(),
    portableData: createDesktopDockPortableData(directory),
  );
}

final class DesktopDesktopTestShell extends StatelessWidget {
  const DesktopDesktopTestShell({
    super.key,
    required this.environment,
    required this.activeDestination,
    required this.content,
    required this.harness,
    this.dockModel,
    this.brightness = Brightness.dark,
    this.locale = const Locale('en'),
  });

  final LayoutEnvironment environment;
  final ClientSection activeDestination;
  final DesktopDesktopFixtureContent content;
  final DesktopDesktopHarness harness;
  final DesktopDockModel? dockModel;
  final Brightness brightness;
  final Locale locale;

  @override
  Widget build(BuildContext context) {
    final bundle = desktopDesktopBundle;
    final variant = bundle.variants[environment.viewport];
    if (variant == null) {
      throw const FormatException('desktop_test_viewport_unregistered');
    }
    final destinationBuilder = variant.destinationBuilders[activeDestination];
    if (destinationBuilder == null) {
      throw const FormatException('desktop_test_destination_unregistered');
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
    harness.scopedState = scopedState;
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
                palette: layoutPaletteFromColors(paletteContext.licoColors),
                child: LayoutChromeFeaturesScope(
                  features: harness.features,
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
                            style: null,
                          ),
                        );
                        return DesktopDesktopShell(
                          dockModel: dockModel,
                          data: LayoutShellBuildContext(
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
                            chrome: DesktopDesktopRecordingChromePort(harness),
                            style: null,
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

LayoutEnvironment desktopDesktopEnvironment({
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

void configureDesktopTestView(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> pumpDesktopShell(
  WidgetTester tester, {
  required DesktopDesktopHarness harness,
  required DesktopDockModel dockModel,
  ClientSection activeDestination = ClientSection.agents,
  Size size = const Size(1280, 800),
  bool reducedMotion = false,
}) async {
  configureDesktopTestView(tester, size);
  await tester.pumpWidget(
    DesktopDesktopTestShell(
      environment: desktopDesktopEnvironment(
        width: size.width,
        height: size.height,
        reducedMotion: reducedMotion,
      ),
      activeDestination: activeDestination,
      content: DesktopDesktopFixtureContent(harness),
      harness: harness,
      dockModel: dockModel,
    ),
  );
  await tester.pump();
  await tester.pump();
}
