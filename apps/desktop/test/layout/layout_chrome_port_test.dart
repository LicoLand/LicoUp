import 'package:flutter/material.dart';
import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/application/features/layout/layout_manager.dart';
import 'package:flutter_client/src/application/features/layout/layout_state_store.dart';
import 'package:flutter_client/src/contracts/agent_usage_models.dart';
import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/layout_profile.dart';
import 'package:flutter_client/src/contracts/presentation/presentation_preferences.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/contracts/target_candidate.dart';
import 'package:flutter_client/src/frontend/layout/layout_chrome_port.dart';
import 'package:flutter_client/src/frontend/layout/layout_focus_coordinator.dart';
import 'package:flutter_client/src/frontend/layout/layout_host.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/shell/client_layout_chrome_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

import 'layout_host_test_fixtures.dart';

void main() {
  test(
    'semantic snapshots are value-equal and meter collections are frozen',
    () {
      const meter = LayoutChromeAllowanceMeterSnapshot(
        kind: 'weekly',
        label: 'Weekly',
        provider: 'provider',
        period: 'week',
        status: 'available',
        value: '75',
        unit: 'percent',
        message: 'resets later',
      );
      final first = LayoutChromeSnapshot(
        status: const LayoutChromeStatusSnapshot(
          message: 'Ready',
          caption: 'Client',
        ),
        allowance: LayoutChromeAllowanceSnapshot(
          targetId: 'agent',
          targetLabel: 'Agent',
          meters: const [meter],
          totalTokens: 100,
          targetTokens: 25,
        ),
      );
      final second = LayoutChromeSnapshot(
        status: const LayoutChromeStatusSnapshot(
          message: 'Ready',
          caption: 'Client',
        ),
        allowance: LayoutChromeAllowanceSnapshot(
          targetId: 'agent',
          targetLabel: 'Agent',
          meters: const [meter],
          totalTokens: 100,
          targetTokens: 25,
        ),
      );

      expect(first, second);
      expect(first.allowance!.usagePercentage, 25);
      expect(
        LayoutChromeAllowanceSnapshot(
          targetId: 'missing',
          targetLabel: 'Missing',
          meters: const [],
          totalTokens: 100,
          targetTokens: null,
        ).usagePercentage,
        isNull,
      );
      expect(() => first.allowance!.meters.add(meter), throwsUnsupportedError);
      expect(
        const LayoutChromeStatusSnapshot(
          message: '',
          caption: 'Fallback',
        ).displayText,
        'Fallback',
      );
    },
  );

  testWidgets(
    'client adapter emits bounded semantic state and owns refresh lifecycle',
    (tester) async {
      final controller =
          ClientController(mobileClientRuntimePlatformOverride: true)
            ..currentSection = ClientSection.agents
            ..selectedConversationAgentId = 'test-agent'
            ..scannedTargets = [_target('test-agent', 'Test Agent')]
            ..agentAllowanceOverrides = const {
              'test-agent': [
                AgentUsageAllowance(
                  kind: 'weekly',
                  label: 'Weekly',
                  provider: 'provider',
                  period: 'week',
                  status: 'available',
                  value: '75',
                  unit: 'percent',
                  source: 'test',
                  message: 'resets later',
                ),
              ],
            }
            ..agentUsageReport = AgentUsageReport.fromAgents(
              generatedAt: '2026-01-01T00:00:00Z',
              agents: [
                AgentUsageAgentSummary(
                  agentId: 'test-agent',
                  label: 'Test Agent',
                  status: 'available',
                  history: const {'totalTokens': 25},
                  traffic: const {},
                  allowances: const [],
                  confidence: 'high',
                ),
              ],
            );
      final scheduled = <VoidCallback>[];
      final refreshes = <String>[];
      var pairingRequests = 0;
      final adapter = ClientLayoutChromeAdapter(
        controller,
        allowanceRefreshInterval: const Duration(milliseconds: 50),
        allowanceRefresher: (targetId) async => refreshes.add(targetId),
        pairingAction: (_) async => pairingRequests += 1,
        postFrameScheduler: scheduled.add,
      );
      addTearDown(() {
        adapter.dispose();
        controller.dispose();
      });

      expect(adapter.value.status.displayText, isNotEmpty);
      expect(adapter.value.allowance!.targetId, 'test-agent');
      expect(adapter.value.allowance!.targetLabel, 'Test Agent');
      expect(adapter.value.allowance!.meters.single.kind, 'weekly');
      expect(adapter.value.allowance!.usagePercentage, 100);
      expect(scheduled, hasLength(1));

      scheduled.single();
      await tester.pump();
      expect(refreshes, ['test-agent']);

      await tester.pump(const Duration(milliseconds: 50));
      expect(refreshes, ['test-agent', 'test-agent']);

      var notifications = 0;
      adapter.addListener(() => notifications += 1);
      controller.selectSection(ClientSection.settings);
      expect(adapter.value.allowance, isNull);
      expect(notifications, 1);

      controller.selectSection(ClientSection.settings);
      expect(notifications, 1);
      await tester.pump(const Duration(milliseconds: 100));
      expect(refreshes, ['test-agent', 'test-agent']);

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => adapter.openPairing(context),
              child: const Text('pair'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('pair'));
      await tester.pump();
      expect(pairingRequests, 1);
    },
  );

  testWidgets('client adapter keeps its last snapshot when refresh fails', (
    tester,
  ) async {
    final controller =
        ClientController(mobileClientRuntimePlatformOverride: true)
          ..currentSection = ClientSection.agents
          ..selectedConversationAgentId = 'test-agent'
          ..scannedTargets = [_target('test-agent', 'Test Agent')];
    final scheduled = <VoidCallback>[];
    final adapter = ClientLayoutChromeAdapter(
      controller,
      allowanceRefreshInterval: const Duration(days: 1),
      allowanceRefresher: (_) async => throw StateError('refresh failed'),
      postFrameScheduler: scheduled.add,
    );
    addTearDown(() {
      adapter.dispose();
      controller.dispose();
    });
    final before = adapter.value;

    scheduled.single();
    await tester.pump();

    expect(adapter.value, before);
    expect(tester.takeException(), isNull);
    adapter.dispose();
  });

  testWidgets('layout host passes the exact chrome port to the active shell', (
    tester,
  ) async {
    LayoutShellBuildContext? observed;
    final runtime = buildFixtureLayoutRuntime(
      onShellBuild: (data) => observed = data,
    );
    final manager = LayoutManager(
      catalog: runtime.catalog,
      preferencesRepository: _MemoryPreferencesRepository(),
      canonicalFallback: _preferences(),
      initialEnvironment: _desktopEnvironment(),
    );
    await manager.initialize();
    final chrome = _RecordingChromePort();
    addTearDown(() {
      manager.dispose();
      chrome.dispose();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: LayoutHost(
          manager: manager,
          registry: runtime.registry,
          stateStore: LayoutStateStore(runtime.catalog),
          environment: _desktopEnvironment(),
          destination: ClientSection.agents,
          onSelectDestination: (_) {},
          destinationLabel: (destination) => destination.name,
          content: const FixtureDestinationContent(),
          focusCoordinator: LayoutFocusCoordinator(),
          primaryFocusTarget: 'primary-landmark',
          loadingBuilder: (_) => const SizedBox(),
          palette: fixtureLayoutPalette,
          chrome: chrome,
        ),
      ),
    );

    expect(observed, isNotNull);
    expect(identical(observed!.chrome, chrome), isTrue);
  });
}

TargetCandidate _target(String id, String label) => TargetCandidate(
  target: id,
  label: label,
  kind: 'agent',
  status: 'ready',
  configured: true,
  confidence: 1,
  adapterStatus: 'implemented',
);

LayoutEnvironment _desktopEnvironment() => LayoutEnvironment.fromConstraints(
  surface: LayoutRuntimeSurface.desktop,
  width: 800,
  height: 600,
  textScale: 1,
  hasPointer: true,
  hasKeyboard: true,
);

PresentationPreferences _preferences() => PresentationPreferences(
  layoutProfileId: LayoutProfileId.parse('workbench'),
  appearancePresetId: 'default-system',
  localePreference: 'system',
);

final class _MemoryPreferencesRepository
    implements PresentationPreferencesRepository {
  PresentationPreferences value = _preferences();

  @override
  Future<PresentationPreferencesLoadResult> load() async =>
      PresentationPreferencesLoadResult(preferences: value);

  @override
  Future<PresentationPreferences> setAppearancePreset(String id) async {
    value = value.copyWith(appearancePresetId: id);
    return value;
  }

  @override
  Future<PresentationPreferences> setLayoutProfile(LayoutProfileId id) async {
    value = value.copyWith(layoutProfileId: id);
    return value;
  }

  @override
  Future<PresentationPreferences> setLocalePreference(String value) async {
    this.value = this.value.copyWith(localePreference: value);
    return this.value;
  }
}

final class _RecordingChromePort extends ValueNotifier<LayoutChromeSnapshot>
    implements LayoutChromePort {
  _RecordingChromePort() : super(const LayoutChromeSnapshot.empty());

  @override
  Future<void> openPairing(BuildContext context) async {}
}
