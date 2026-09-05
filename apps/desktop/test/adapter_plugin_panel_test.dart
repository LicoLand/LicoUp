import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/composition/features/plugin_management/plugin_management_feature_composition.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/presentation_preferences.dart';
import 'package:licoup/src/frontend/features/plugin_management/ui/adapter_plugin_panel.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/lico_icon_button.dart';
import 'package:licoup/src/frontend/shared/ui/lico_pane_title_bar.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/platform/native_client/agent_service.dart';

void main() {
  testWidgets('adapter cards fit at minimum desktop size at 200% text scale', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(760, 560);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await _pumpPanel(tester, locale: const Locale('zh'));

    expect(find.byKey(const Key('adapter-plugin-kimi-code')), findsOneWidget);
    expect(find.byKey(const Key('adapter-plugin-claude-code')), findsOneWidget);
    expect(find.byKey(const Key('adapter-plugin-antigravity')), findsOneWidget);
    expect(
      find.byKey(const Key('adapter-install-antigravity-acp-bridge')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('adapter cards fit at compact width at 200% text scale', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await _pumpPanel(tester, locale: const Locale('zh'));

    for (final agentId in const ['kimi-code', 'claude-code', 'antigravity']) {
      await tester.scrollUntilVisible(
        find.byKey(Key('adapter-plugin-$agentId')),
        240,
        scrollable: find.byType(Scrollable).first,
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('adapter cards render in the wide two-column layout', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpPanel(tester, locale: const Locale('en'));

    expect(find.byKey(const Key('adapter-plugin-kimi-code')), findsOneWidget);
    expect(find.byKey(const Key('adapter-plugin-claude-code')), findsOneWidget);
    expect(find.byKey(const Key('adapter-plugin-antigravity')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'plugin pane title bar uses the shared refresh control and stays aligned',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await _pumpPanel(tester, locale: const Locale('zh'));

      expect(find.byType(LicoPaneTitleBar), findsOneWidget);
      expect(find.byKey(const Key('adapter-plugin-title-bar')), findsOneWidget);
      expect(find.byKey(const Key('adapter-plugin-refresh')), findsOneWidget);
      expect(find.byKey(const Key('adapter-plugin-search')), findsNothing);
      expect(find.text('插件管理'), findsOneWidget);
      expect(find.byType(IconButton), findsNothing);

      final title = tester.getRect(find.text('插件管理'));
      final titleBar = tester.getRect(
        find.byKey(const Key('adapter-plugin-title-bar')),
      );
      final refresh = tester.getRect(
        find.byKey(const Key('adapter-plugin-refresh')),
      );
      expect((title.center.dy - refresh.center.dy).abs(), lessThan(1));
      expect(
        refresh.right,
        closeTo(titleBar.right - LicoContentSpacing.paneInset, 1),
      );
      expect(refresh.left, greaterThan(title.right));

      final button = tester.widget<LicoIconButton>(find.byType(LicoIconButton));
      expect(button.shape, LicoIconButtonShape.circle);
      expect(button.tone, LicoIconButtonTone.ghost);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('adapter cards group native capabilities and adapter plugins', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpPanel(tester, locale: const Locale('zh'));

    // Delivery-channel suffixes are stripped from card titles.
    expect(find.text('Kimi Code'), findsOneWidget);
    expect(find.text('Kimi Code - CLI'), findsNothing);
    expect(find.text('Claude Code'), findsOneWidget);
    expect(find.text('Antigravity'), findsOneWidget);

    // Native capability chips render with detection states and live evidence.
    expect(find.text('原生能力'), findsWidgets);
    expect(
      find.byKey(const Key('adapter-capability-antigravity-desktop')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('adapter-capability-kimi-code-cli')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('adapter-capability-kimi-code-acp')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('adapter-capability-kimi-code-web-server')),
      findsOneWidget,
    );
    expect(find.text('ACP'), findsOneWidget);
    expect(find.text('Web Server'), findsOneWidget);
    expect(find.text('PID 58627 · kimi · :58627'), findsOneWidget);
    expect(find.text('已检测'), findsWidgets);
    expect(find.text('PID 4242 · claude'), findsOneWidget);
    expect(
      find.byKey(const Key('adapter-capability-live-antigravity-desktop')),
      findsOneWidget,
    );
    expect(find.text('未运行'), findsWidgets);

    // The Antigravity adapter plugin entry replaces the old meta tiles.
    expect(find.text('适配插件'), findsWidgets);
    expect(
      find.byKey(const Key('adapter-plugin-entry-antigravity-acp-bridge')),
      findsOneWidget,
    );
    expect(find.text('ACP Bridge'), findsOneWidget);
    expect(find.text('驱动'), findsNothing);
    expect(find.text('通道'), findsNothing);

    // An installed plugin exposes a disabled update action and a warning
    // uninstall action below the in-card divider.
    final updateButton = tester.widget<FilledButton>(
      find.byKey(const Key('adapter-update-claude-code-lico-up-codex')),
    );
    expect(updateButton.onPressed, isNull);
    expect(
      find.byKey(const Key('adapter-uninstall-claude-code-lico-up-codex')),
      findsOneWidget,
    );
    expect(find.text('更新'), findsOneWidget);
    expect(find.text('卸载'), findsOneWidget);

    // Optional collaboration remains implemented but is intentionally absent
    // from the client surface until the product flow is ready again.
    expect(find.text('协作插件'), findsNothing);
    expect(find.text('LicoMesh'), findsNothing);
    expect(
      find.byKey(const Key('optional-collaboration-settings')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('managed plugin action executes only after user confirmation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final service = _CatalogAgentService();
    final controller = ClientController(
      agentService: service,
      presentationPreferencesRepository: _PanelPreferencesRepository(),
    );
    addTearDown(controller.dispose);
    await controller.adapterPluginController.refresh();
    final feature = PluginManagementFeatureComposition(controller);
    addTearDown(feature.dispose);
    await _pumpBinding(tester, feature, const Locale('en'));
    service.calls.clear();

    await tester.tap(
      find.byKey(const Key('adapter-install-antigravity-acp-bridge')),
    );
    await tester.pumpAndSettle();

    expect(service.calls, isEmpty);
    expect(find.byKey(const Key('plugin-lifecycle-plan')), findsOneWidget);
    expect(find.text('Install ACP Bridge?'), findsOneWidget);

    await tester.tap(find.byKey(const Key('confirm-adapter-install')));
    await tester.pumpAndSettle();

    expect(service.calls, [
      ['adapter', 'antigravity', 'install'],
      ['adapter', 'catalog'],
    ]);
    expect(find.text('Adapter installed.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Codex plugin preserves status-plan-confirm-install order and hides permit',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = _CodexPluginAgentService();
      final controller = ClientController(
        agentService: service,
        presentationPreferencesRepository: _PanelPreferencesRepository(),
      );
      addTearDown(controller.dispose);
      controller.scannedTargets = [
        TargetCandidate(
          target: 'codex',
          label: 'Codex',
          kind: 'cli',
          status: TargetCandidateStatus.detected,
          configured: true,
          confidence: 1,
          binaryPath: _CodexPluginAgentService.syntheticBinary,
          adapterStatus: 'ready',
        ),
      ];
      await controller.adapterPluginController.refresh();
      final feature = PluginManagementFeatureComposition(controller);
      addTearDown(feature.dispose);
      await _pumpBinding(tester, feature, const Locale('en'));
      service.calls.clear();

      await tester.tap(
        find.byKey(const Key('adapter-install-codex-lico-up-codex')),
      );
      await tester.pumpAndSettle();

      expect(service.calls, [
        [
          'adapter',
          'codex',
          'plugin',
          'status',
          '--binary-path',
          _CodexPluginAgentService.syntheticBinary,
        ],
        [
          'adapter',
          'codex',
          'plugin',
          'plan',
          '--binary-path',
          _CodexPluginAgentService.syntheticBinary,
        ],
      ]);
      expect(find.byKey(const Key('plugin-lifecycle-plan')), findsOneWidget);
      expect(find.text('Install LicoUp Codex Plugin?'), findsOneWidget);
      expect(find.textContaining('LicoLand/LicoUp-Plugins'), findsOneWidget);
      expect(find.textContaining('v1.2.3'), findsOneWidget);
      expect(
        find.textContaining(_CodexPluginAgentService.syntheticConfirmation),
        findsNothing,
      );
      expect(
        find.textContaining(_CodexPluginAgentService.syntheticBinary),
        findsNothing,
      );

      await tester.tap(find.byKey(const Key('confirm-adapter-install')));
      await tester.pumpAndSettle();

      expect(service.calls.skip(2), [
        [
          'adapter',
          'codex',
          'plugin',
          'install',
          '--binary-path',
          _CodexPluginAgentService.syntheticBinary,
          '--confirmation',
          _CodexPluginAgentService.syntheticConfirmation,
          '--confirmed',
        ],
        ['adapter', 'catalog'],
      ]);
      expect(
        find.textContaining('LicoUp Codex Plugin is installed'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _pumpPanel(WidgetTester tester, {required Locale locale}) async {
  final controller = ClientController(
    agentService: _CatalogAgentService(),
    presentationPreferencesRepository: _PanelPreferencesRepository(),
  );
  addTearDown(controller.dispose);
  // Explicit application-owned preload: panel mounting must not refresh.
  await controller.adapterPluginController.refresh();
  final feature = PluginManagementFeatureComposition(controller);
  addTearDown(feature.dispose);
  await _pumpBinding(tester, feature, locale);
}

Future<void> _pumpBinding(
  WidgetTester tester,
  PluginManagementFeatureComposition feature,
  Locale locale,
) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      supportedLocales: LicoStrings.supportedLocales,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      theme: buildLicoTheme(
        platformBrightness: Brightness.dark,
      ).copyWith(platform: TargetPlatform.macOS),
      home: Scaffold(body: AdapterPluginPanel(binding: feature.binding)),
    ),
  );
  await tester.pumpAndSettle();
}

final class _CatalogAgentService extends AgentService {
  _CatalogAgentService() : super(persistentStdioRpcEnabled: false);

  final List<List<String>> calls = [];
  var _installed = false;

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) async {
    calls.add(List.unmodifiable(args));
    if (args.join(' ') == 'adapter antigravity install') {
      _installed = true;
      return const {'ok': true};
    }
    return {
      'ok': true,
      'schemaVersion': 'lico.adapter-plugin-catalog.v1',
      'adapters': [
        {
          'agentId': 'kimi-code',
          'label': 'Kimi Code - CLI',
          'driverId': 'kimi-code',
          'runtimeProtocol': 'kimi-code-acp-v1-stdio-ndjson',
          'laneFamily': 'acp',
          'managementKind': 'bundled-acp',
          'installationState': 'not-required',
          'readiness': 'ready',
          'lifecycleActions': <String>[],
          'nativeCapabilities': [
            {
              'kind': 'cli',
              'detected': true,
              'running': true,
              'pid': 67099,
              'processName': 'kimi',
            },
            {'kind': 'acp', 'detected': true, 'running': false},
            {
              'kind': 'web-server',
              'detected': true,
              'running': true,
              'pid': 58627,
              'processName': 'kimi',
              'port': 58627,
            },
          ],
          'adapterPlugins': <Map<String, Object>>[],
        },
        {
          'agentId': 'claude-code',
          'label': 'Claude Code - CLI',
          'driverId': 'claude-code',
          'runtimeProtocol': 'claude-code-cli-stream-json',
          'laneFamily': 'official-native',
          'managementKind': 'native',
          'installationState': 'not-required',
          'readiness': 'unverified',
          'lifecycleActions': <String>[],
          'nativeCapabilities': [
            {
              'kind': 'cli',
              'detected': true,
              'running': true,
              'pid': 4242,
              'processName': 'claude',
            },
          ],
          'adapterPlugins': [
            {
              'id': 'lico-up-codex',
              'label': 'LicoUp Codex Plugin',
              'detail': 'lico-subagent-mcp',
              'installationState': 'installed',
              'lifecycleActions': ['uninstall'],
            },
          ],
        },
        {
          'agentId': 'antigravity',
          'label': 'Antigravity - CLI',
          'driverId': 'antigravity',
          'runtimeProtocol': 'antigravity-cli-argv-hook-v1',
          'laneFamily': 'bridge-supervised',
          'managementKind': 'managed-bridge',
          'installationState': 'not-installed',
          'readiness': 'partial',
          'lifecycleActions': ['install'],
          'nativeCapabilities': [
            {
              'kind': 'desktop',
              'detected': true,
              'running': true,
              'pid': 65773,
              'processName': 'antigravity',
            },
            {'kind': 'cli', 'detected': true, 'running': false},
          ],
          'adapterPlugins': [
            {
              'id': 'acp-bridge',
              'label': 'ACP Bridge',
              'detail': 'antigravity-cli-argv-hook-v1',
              'installationState': _installed ? 'installed' : 'not-installed',
              'lifecycleActions': [_installed ? 'uninstall' : 'install'],
            },
          ],
        },
      ],
    };
  }
}

final class _CodexPluginAgentService extends AgentService {
  _CodexPluginAgentService() : super(persistentStdioRpcEnabled: false);

  static const syntheticBinary = 'synthetic/bin/codex';
  static const syntheticConfirmation = 'synthetic-confirmation-digest';

  final List<List<String>> calls = [];
  var _installed = false;

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) async {
    calls.add(List.unmodifiable(args));
    if (args.length >= 4 &&
        args[0] == 'adapter' &&
        args[1] == 'codex' &&
        args[2] == 'plugin') {
      return switch (args[3]) {
        'status' => {'ok': true, 'ready': false},
        'plan' => {
          'ok': true,
          'requiresConfirmation': true,
          'digest': syntheticConfirmation,
          'marketplaceSource': 'LicoLand/LicoUp-Plugins',
          'marketplaceRelease': 'v1.2.3',
          'pluginVersion': '1.2.3',
        },
        'install' => _install(),
        _ => {'ok': false},
      };
    }
    return {
      'ok': true,
      'schemaVersion': 'lico.adapter-plugin-catalog.v1',
      'adapters': [
        {
          'agentId': 'codex',
          'label': 'Codex - CLI',
          'driverId': 'codex',
          'runtimeProtocol': 'codex-app-server-jsonrpc',
          'laneFamily': 'official-native',
          'managementKind': 'native',
          'installationState': 'not-required',
          'readiness': 'ready',
          'lifecycleActions': <String>[],
          'nativeCapabilities': [
            {'kind': 'cli', 'detected': true, 'running': false},
          ],
          'adapterPlugins': [
            {
              'id': 'lico-up-codex',
              'label': 'LicoUp Codex Plugin',
              'detail': 'lico-subagent-mcp',
              'installationState': _installed ? 'installed' : 'not-installed',
              'lifecycleActions': _installed ? <String>[] : ['install'],
            },
          ],
        },
      ],
    };
  }

  Map<String, dynamic> _install() {
    _installed = true;
    return {'ok': true, 'installed': true};
  }
}

final class _PanelPreferencesRepository
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
