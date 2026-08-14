import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/presentation_preferences.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/frontend/shell/client_shell.dart';
import 'package:licoup/src/platform/native_client/agent_service.dart';

void main() {
  testWidgets(
    'desktop user can visit every primary destination at minimum size',
    (tester) async {
      tester.view.physicalSize = const Size(760, 560);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      final controller = ClientController(
        agentService: _UiAgentService(),
        presentationPreferencesRepository: _JourneyPreferencesRepository(),
      );
      addTearDown(controller.dispose);
      await controller.layoutManager.initialize();

      await tester.pumpWidget(
        MaterialApp(
          supportedLocales: LicoStrings.supportedLocales,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          theme: buildLicoTheme(
            platformBrightness: Brightness.dark,
          ).copyWith(platform: TargetPlatform.macOS),
          home: ClientShell(controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      for (final section in const [
        ClientSection.skillHub,
        ClientSection.pluginManagement,
        ClientSection.monitoring,
        ClientSection.agents,
      ]) {
        await tester.tap(find.byKey(Key('messaging-rail-nav-${section.name}')));
        await tester.pump(const Duration(milliseconds: 250));
        expect(
          find.byKey(Key('messaging-desktop-destination-${section.name}')),
          findsOneWidget,
        );
        expect(
          tester.takeException(),
          isNull,
          reason: '${section.name} must fit at 200% text scale',
        );
      }

      await tester.tap(find.byKey(const Key('messaging-rail-settings-button')));
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        find.byKey(const Key('messaging-desktop-destination-settings')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('compact mobile user can navigate at 200% text scale', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    final controller = ClientController(
      agentService: _UiAgentService(),
      presentationPreferencesRepository: _JourneyPreferencesRepository(),
      mobileClientRuntimePlatformOverride: true,
    );
    addTearDown(controller.dispose);
    await controller.layoutManager.initialize();

    await tester.pumpWidget(
      MaterialApp(
        supportedLocales: LicoStrings.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        theme: buildLicoTheme(
          platformBrightness: Brightness.dark,
        ).copyWith(platform: TargetPlatform.android),
        home: ClientShell(controller: controller),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('messaging-mobile-menu-button')));
    await tester.pump(const Duration(milliseconds: 180));
    await tester.tap(
      find.byKey(const Key('messaging-mobile-compact-navigation-settings')),
    );
    await tester.pump(const Duration(milliseconds: 250));
    expect(controller.currentSection, ClientSection.settings);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const Key('messaging-mobile-menu-button')));
    await tester.pump(const Duration(milliseconds: 180));
    await tester.tap(
      find.byKey(const Key('messaging-mobile-compact-navigation-agents')),
    );
    await tester.pump(const Duration(milliseconds: 250));
    expect(controller.currentSection, ClientSection.agents);
    expect(tester.takeException(), isNull);
  });
}

final class _UiAgentService extends AgentService {
  _UiAgentService() : super(persistentStdioRpcEnabled: false);

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) async => const {
    'ok': true,
    'schemaVersion': 'lico.adapter-plugin-catalog.v1',
    'adapters': <Map<String, dynamic>>[],
  };
}

final class _JourneyPreferencesRepository
    implements PresentationPreferencesRepository {
  var _preferences = PresentationPreferences(
    layoutProfileId: LayoutProfileId.parse('messaging'),
    appearancePresetId: 'default-system',
    localePreference: 'system',
  );

  @override
  Future<PresentationPreferencesLoadResult> load() async =>
      PresentationPreferencesLoadResult(preferences: _preferences);

  @override
  Future<PresentationPreferences> setAppearancePreset(String id) async =>
      _preferences = _preferences.copyWith(appearancePresetId: id);

  @override
  Future<PresentationPreferences> setLayoutProfile(LayoutProfileId id) async =>
      _preferences = _preferences.copyWith(layoutProfileId: id);

  @override
  Future<PresentationPreferences> setLocalePreference(
    String preference,
  ) async => _preferences = _preferences.copyWith(localePreference: preference);
}
