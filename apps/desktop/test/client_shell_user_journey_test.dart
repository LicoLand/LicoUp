import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/presentation_preferences.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/messaging/messaging_sidebar_navigation.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/platform/native_client/agent_service.dart';

import 'presentation/composed_client_shell_test_helper.dart';

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
          home: composedClientShell(controller),
        ),
      );
      await tester.pumpAndSettle();

      // The app lands on 对话 with the bottom nav embedded in the
      // conversation-list column.
      expect(
        find.byKey(const Key('messaging-sidebar-nav-conversations')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('messaging-sidebar-nav-features')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      // Keep-alive contract: destination panes stay mounted across switches,
      // so a round trip never re-runs initState (no repeated refresh intents
      // or store reloads). Capture element identity now and re-check after
      // the round trip below.
      Element agentsElement() => tester.element(
        find.byKey(
          const Key('dashboard-desktop-destination-agents'),
          skipOffstage: false,
        ),
      );
      final agentsElementOnLand = agentsElement();

      // The 功能 bottom nav opens the features home (agent hub).
      await tester.tap(find.byKey(const Key('messaging-sidebar-nav-features')));
      await tester.pump(const Duration(milliseconds: 250));
      expect(controller.currentSection, ClientSection.agentHub);
      expect(
        find.byKey(const Key('dashboard-desktop-destination-agentHub')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      // A 功能 row opens plugin management.
      await tester.tap(
        find.byKey(const Key('messaging-sidebar-list-pluginManagement')),
      );
      await tester.pump(const Duration(milliseconds: 250));
      expect(controller.currentSection, ClientSection.pluginManagement);
      expect(
        find.byKey(const Key('dashboard-desktop-destination-pluginManagement')),
        findsOneWidget,
      );
      expect(
        tester.takeException(),
        isNull,
        reason: 'plugins list must fit at 200% text scale',
      );

      // 设置 opens settings.
      await tester.tap(find.byKey(const Key('messaging-sidebar-nav-settings')));
      await tester.pump(const Duration(milliseconds: 250));
      expect(controller.currentSection, ClientSection.settings);
      expect(
        find.byKey(const Key('dashboard-desktop-destination-settings')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      // Re-entering 功能 from settings hosts the agent hub again.
      await tester.tap(find.byKey(const Key('messaging-sidebar-nav-features')));
      await tester.pump(const Duration(milliseconds: 250));
      expect(controller.currentSection, ClientSection.agentHub);

      // The stats row opens the monitoring destination, which keeps the
      // unified sidebar like every other feature pane.
      await tester.tap(
        find.byKey(const Key('messaging-sidebar-list-statsPanel')),
      );
      await tester.pump(const Duration(milliseconds: 250));
      expect(controller.currentSection, ClientSection.monitoring);
      expect(
        find.byKey(const Key('dashboard-desktop-destination-monitoring')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('messaging-sidebar-search')), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Every destination keeps the sidebar nav; switch straight to 对话 and
      // finish on 设置.
      await tester.tap(
        find.byKey(const Key('messaging-sidebar-nav-conversations')),
      );
      await tester.pump(const Duration(milliseconds: 250));
      expect(controller.currentSection, ClientSection.agents);
      await tester.tap(find.byKey(const Key('messaging-sidebar-nav-settings')));
      await tester.pump(const Duration(milliseconds: 250));
      expect(controller.currentSection, ClientSection.settings);
      expect(tester.takeException(), isNull);

      // The whole round trip (功能 → 插件 → 设置 → 统计 → 对话 → 设置) never
      // remounted the agents pane.
      expect(identical(agentsElementOnLand, agentsElement()), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('settings scroll-spy keeps the sidebar selection in sync', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

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
        home: composedClientShell(controller),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('messaging-sidebar-nav-settings')));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<MessagingSettingsSectionList>(
            find.byType(MessagingSettingsSectionList),
          )
          .selectedIndex,
      0,
    );

    // One fast fling through the content: scroll notifications fire before
    // the layout pass, so without the scroll-end reconcile the sidebar would
    // stay on 通用. After the settle, the selection must follow the content.
    await tester.drag(
      find.byKey(const Key('settings-content-scroll')),
      const Offset(0, -600),
    );
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<MessagingSettingsSectionList>(
            find.byType(MessagingSettingsSectionList),
          )
          .selectedIndex,
      1,
      reason: 'sidebar selection must follow the scrolled-to section (外观)',
    );
    expect(tester.takeException(), isNull);
  });

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
        home: composedClientShell(controller),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('dashboard-mobile-menu-button')));
    await tester.pump(const Duration(milliseconds: 180));
    await tester.tap(
      find.byKey(const Key('dashboard-mobile-compact-navigation-settings')),
    );
    await tester.pump(const Duration(milliseconds: 250));
    expect(controller.currentSection, ClientSection.settings);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const Key('dashboard-mobile-menu-button')));
    await tester.pump(const Duration(milliseconds: 180));
    await tester.tap(
      find.byKey(const Key('dashboard-mobile-compact-navigation-agents')),
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
    layoutProfileId: LayoutProfileId.parse('dashboard'),
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
