// V7-FI: the production root closes every migrated frontend binding source on
// one application-scope runtime.
//
// The composition root installs every migrated binding's presentation source
// in one Riverpod scope; the shell providers and the renderer chrome observe
// those sources through the same `PresentationRuntime`. These tests prove the
// closure without faking a feature source: every provider is read from a
// container built from `ClientAppComposition.presentationOverrides` over a real
// controller with bounded fixture backends.
//
// Conversation scope note: the conversation entry here is the prepared
// markdown owner (port) installed by the composition. The conversation
// workspace's message/catalog/composer planes still read the conversation
// binding projections directly and are tracked separately; this test does not
// claim the whole Conversation binding has been migrated.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/presentation_runtime.dart';

import 'package:licoup/src/composition/client_app_composition.dart';
import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/presentation/agent_hub/agent_hub_providers.dart';
import 'package:licoup/src/presentation/agents/agents_providers.dart';
import 'package:licoup/src/presentation/conversation/conversation_markdown_port.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_providers.dart';
import 'package:licoup/src/presentation/models/models_providers.dart';
import 'package:licoup/src/presentation/monitoring/monitoring_providers.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_providers.dart';
import 'package:licoup/src/presentation/search/search_providers.dart';
import 'package:licoup/src/presentation/settings/settings_providers.dart';
import 'package:licoup/src/presentation/shell/shell_providers.dart';
import 'package:licoup/src/presentation/skill_hub/skill_hub_providers.dart';
import 'package:licoup/src/presentation/targets/targets_providers.dart';
import 'package:licoup/src/projections/conversation/conversation_markdown_preparation.dart';

import '../layout/fixtures/production_client_shell_fixture.dart';

void main() {
  test(
    'the root scope installs every migrated binding source on one runtime',
    () async {
      final fixture = await ProductionClientShellFixture.create(
        profileId: LayoutProfileId.parse('dashboard'),
        surface: LayoutRuntimeSurface.desktop,
        destination: ClientSection.agents,
        size: const Size(1280, 800),
        brightness: Brightness.dark,
      );
      addTearDown(fixture.dispose);
      final primaryTargetId = fixture.controller.scannedTargets.first.target;
      final composition = ClientAppComposition(controller: fixture.controller);
      addTearDown(composition.dispose);
      final container = ProviderContainer(
        overrides: composition.presentationOverrides,
      );
      addTearDown(container.dispose);

      // Exactly one runtime: the root scope resolves the composition runtime, so
      // the renderer chrome and every feature provider share one observation
      // store instead of opening parallel subscriptions.
      expect(
        identical(
          container.read(presentationRuntimeProvider),
          composition.presentationRuntime,
        ),
        isTrue,
      );

      // The six shell region planes resolve to the composition-owned adapters.
      expect(
        identical(
          container.read(shellAppearanceSourceProvider),
          composition.shellSources.appearance,
        ),
        isTrue,
      );
      expect(
        identical(
          container.read(shellLocaleSourceProvider),
          composition.shellSources.locale,
        ),
        isTrue,
      );
      expect(
        identical(
          container.read(shellLayoutSourceProvider),
          composition.shellSources.layout,
        ),
        isTrue,
      );
      expect(
        identical(
          container.read(shellEnvironmentSourceProvider),
          composition.shellSources.environment,
        ),
        isTrue,
      );
      expect(
        identical(
          container.read(shellNavigationSourceProvider),
          composition.shellSources.navigation,
        ),
        isTrue,
      );
      expect(
        identical(
          container.read(shellStatusSourceProvider),
          composition.shellSources.status,
        ),
        isTrue,
      );

      // Every remaining binding source is a real adapter, not the disabled
      // default, and admits a first snapshot through the shared runtime.
      final runtime = composition.presentationRuntime;
      final sources = <String, Future<bool> Function()>{
        'chrome': () => _admits(runtime, composition.chromeSource),
        'search': () => _admits(runtime, container.read(searchSourceProvider)),
        'agents': () =>
            _admits(runtime, container.read(agentsCatalogSourceProvider)),
        'targets': () =>
            _admits(runtime, container.read(targetsCatalogSourceProvider)),
        'monitoring': () =>
            _admits(runtime, container.read(monitoringUsageSourceProvider)),
        'models': () =>
            _admits(runtime, container.read(modelsCatalogSourceProvider)),
        'agent_hub': () =>
            _admits(runtime, container.read(agentHubCatalogSourceProvider)),
        'settings': () =>
            _admits(runtime, container.read(settingsGeneralSourceProvider)),
        'plugin_catalog': () =>
            _admits(runtime, container.read(pluginCatalogSourceProvider)),
        'plugin_collaboration': () =>
            _admits(runtime, container.read(pluginCollaborationSourceProvider)),
        'skill_hub': () =>
            _admits(runtime, container.read(skillHubCatalogSourceProvider)),
        'mobile_relay_pairing': () =>
            _admits(runtime, container.read(mobileRelayPairingSourceProvider)),
        'mobile_relay_trust': () =>
            _admits(runtime, container.read(mobileRelayTrustSourceProvider)),
        'mobile_relay_approvals': () => _admits(
          runtime,
          container.read(mobileRelayApprovalsSourceProvider),
        ),
        'mobile_relay_transfers': () => _admits(
          runtime,
          container.read(mobileRelayTransfersSourceProvider),
        ),
        'mobile_relay_capabilities': () => _admits(
          runtime,
          container.read(mobileRelayCapabilitiesSourceProvider),
        ),
        'mobile_relay_home': () =>
            _admits(runtime, container.read(mobileRelayHomeSourceProvider)),
        'shell_appearance': () =>
            _admits(runtime, composition.shellSources.appearance),
        'shell_locale': () => _admits(runtime, composition.shellSources.locale),
        'shell_layout': () => _admits(runtime, composition.shellSources.layout),
        'shell_environment': () =>
            _admits(runtime, composition.shellSources.environment),
        'shell_navigation': () =>
            _admits(runtime, composition.shellSources.navigation),
        'shell_status': () => _admits(runtime, composition.shellSources.status),
      };
      for (final entry in sources.entries) {
        expect(
          await entry.value(),
          isTrue,
          reason: '${entry.key} never admitted a snapshot',
        );
      }

      // The admitted values carry the real owner's data, not an empty stub.
      final agents = await _settle(container, agentsCatalogProjectionProvider);
      expect(
        agents.requireValue.targets.map((target) => target.id),
        contains(primaryTargetId),
      );
      final targets = await _settle(
        container,
        targetsCatalogProjectionProvider,
      );
      expect(
        targets.requireValue.targets.map((target) => target.id),
        contains(primaryTargetId),
      );
      final monitoring = await _settle(
        container,
        monitoringUsageProjectionProvider,
      );
      expect(monitoring.requireValue.usage, isNotEmpty);
      for (final provider in <ProviderListenable<AsyncValue<Object?>>>[
        modelsCatalogProjectionProvider,
        agentHubCatalogProjectionProvider,
        searchProjectionProvider,
        settingsGeneralSnapshotProvider,
        skillHubCatalogSnapshotProvider,
        pluginCatalogSnapshotProvider,
        mobileRelayPairingSnapshotProvider,
      ]) {
        final snapshot = await _settle(container, provider);
        expect(snapshot.hasValue, isTrue, reason: '$provider never settled');
      }

      // The conversation binding's prepared-markdown owner is the composition
      // adapter over the same runtime, not the disabled port.
      expect(
        container.read(conversationMarkdownPortProvider),
        isA<ConversationMarkdownPreparation>(),
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}

Future<bool> _admits<T>(
  PresentationRuntime runtime,
  PresentationSource<T> source,
) async {
  final observation = runtime.observe(source);
  ResourceSnapshot<T>? first;
  final subscription = observation.stream.listen((snapshot) {
    first ??= snapshot;
  });
  for (var attempt = 0; attempt < 60 && first == null; attempt++) {
    await pumpEventQueue(times: 2);
  }
  await subscription.cancel();
  await observation.close();
  return first != null;
}

Future<AsyncValue<T>> _settle<T>(
  ProviderContainer container,
  ProviderListenable<AsyncValue<T>> provider,
) async {
  final subscription = container.listen<AsyncValue<T>>(
    provider,
    (previous, next) {},
    fireImmediately: true,
  );
  addTearDown(subscription.close);
  for (var attempt = 0; attempt < 60; attempt++) {
    final value = container.read(provider);
    if (!value.isLoading) return value;
    await pumpEventQueue(times: 2);
  }
  return container.read(provider);
}
