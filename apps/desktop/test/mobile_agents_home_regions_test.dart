import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/composition/features/mobile_relay/mobile_relay_feature_composition.dart';
import 'package:licoup/src/contracts/mobile_relay/mobile_relay_config.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_agents_home.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/agents/agents_binding.dart';
import 'package:licoup/src/presentation/agents/agents_effect.dart';
import 'package:licoup/src/presentation/agents/agents_intent.dart';
import 'package:licoup/src/presentation/agents/agents_projection.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_projection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

import 'fixtures/mobile_relay_binding_fixture.dart';
import 'fixtures/mobile_relay_presentation_fixture.dart';

void main() {
  testWidgets('the agents home list follows the relay home region', (
    tester,
  ) async {
    final projection = mobileRelayProjectionFixture(
      peers: const [
        RelayPeerProjection(
          id: 'device-1',
          displayName: 'Workstation',
          connected: true,
          selected: true,
        ),
      ],
    );
    final relay = MobileRelayBindingFixture(projection: projection);
    final presentation = MobileRelayPresentationFixture(projection: projection);
    addTearDown(relay.dispose);
    addTearDown(presentation.dispose);
    final relayIntents = relay.intents.values;

    await tester.pumpWidget(
      ProviderScope(
        overrides: presentation.overrides,
        child: MaterialApp(
          theme: buildLicoTheme().copyWith(platform: TargetPlatform.macOS),
          home: Scaffold(
            body: MobileAgentsHome(
              agents: _agentsBinding(),
              relay: relay.binding,
              conversationContentBuilder: (context, target) =>
                  const SizedBox.shrink(),
              configurationContentBuilder: (context, target) =>
                  const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('mobile-paired-device-device-1')), findsOne);
    expect(
      find.byKey(const Key('mobile-agent-list-item-codex')),
      findsOneWidget,
    );

    presentation.home.publish(
      MobileRelayPresentationFixture.homeOf(
        mobileRelayProjectionFixture(
          peers: const [
            RelayPeerProjection(
              id: 'device-1',
              displayName: 'Workstation',
              connected: true,
              selected: true,
            ),
          ],
          pinnedHomeEntryIds: const ['device:device-1'],
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('mobile-paired-device-device-1')), findsOne);
    expect(relayIntents, isEmpty);
  });

  testWidgets('the real feature composition feeds the agents home list', (
    tester,
  ) async {
    final controller = ClientController(
      mobileClientRuntimePlatformOverride: true,
    );
    final feature = MobileRelayFeatureComposition(
      relay: controller.mobileRelayController,
      secureMesh: controller.secureMeshController,
      homeLayout: controller.mobileHomeLayoutController,
      readMobileRuntime: () => controller.mobileClientRuntimePlatform,
    );
    addTearDown(() async {
      await feature.dispose();
      controller.dispose();
    });
    controller.mobileRelayConfig = MobileRelayConfig.defaults().copyWith(
      stationBaseUrl: 'https://station.example.test',
      pcClientName: 'ARC Desktop',
      pairingId: 'pairing_desktop',
      mobileTokenPresent: true,
      paired: true,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: feature.providerOverrides,
        child: MaterialApp(
          theme: buildLicoTheme().copyWith(platform: TargetPlatform.macOS),
          home: Scaffold(
            body: MobileAgentsHome(
              agents: _agentsBinding(),
              relay: feature.binding,
              conversationContentBuilder: (context, target) =>
                  const SizedBox.shrink(),
              configurationContentBuilder: (context, target) =>
                  const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(feature.binding.projection.current.peers, hasLength(1));
    expect(
      find.byKey(
        Key(
          'mobile-paired-device-'
          '${controller.mobileRelayConfig.deviceTabs.single.id}',
        ),
      ),
      findsOneWidget,
    );
  });
}

AgentsBinding _agentsBinding() {
  return AgentsBinding(
    projection: _StaticProjection<AgentsProjection>(
      AgentsProjection(
        targets: [
          AgentTargetProjection(
            id: 'codex',
            displayName: 'Assistant',
            available: true,
            pinned: false,
            capabilityLabel: 'detected',
          ),
        ],
        targetDetails: const [],
        selectedAgentId: 'codex',
        workingDirectoryLabel: '',
        phase: PresentationPhase.ready,
      ),
    ),
    intents: _RecordingIntents(),
    effects: const _NoEffects(),
  );
}

final class _StaticProjection<T> implements ProjectionSource<T> {
  _StaticProjection(this._current);

  final T _current;

  @override
  T get current => _current;

  @override
  Stream<ProjectionUpdate<T>> get changes => const Stream.empty();
}

final class _RecordingIntents implements IntentSink<AgentsIntent> {
  final List<AgentsIntent> values = [];

  @override
  void send(AgentsIntent intent) => values.add(intent);
}

final class _NoEffects implements EffectSource<AgentsEffect> {
  const _NoEffects();

  @override
  Stream<AgentsEffect> get effects => const Stream.empty();
}
