import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/composition/client_app_composition.dart';
import 'package:licoup/src/composition/client_composition_set.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';

/// The declaration is the one place that decides which capabilities exist, so
/// these tests assert the two constants' contents field by field — the
/// declaration is typed, so there is no string key to iterate — and that the
/// catalogue projection follows the declaration it was given rather than a
/// fixed list.
void main() {
  test('the minimum declaration serves only the features it names', () {
    const minimum = ClientCompositionSet.minimum;

    expect(minimum.agents, isTrue);
    expect(minimum.conversation, isTrue);
    expect(minimum.targets, isTrue);
    expect(minimum.chrome, isTrue);
    expect(minimum.monitoring, isTrue);
    expect(minimum.agentHub, isFalse);
    expect(minimum.mobileRelay, isFalse);
    expect(minimum.models, isFalse);
    expect(minimum.pluginManagement, isFalse);
    expect(minimum.search, isFalse);
    expect(minimum.settings, isFalse);
    expect(minimum.skillHub, isFalse);
  });

  test('the full declaration adds exactly the optional features', () {
    const full = ClientCompositionSet.full;
    const minimum = ClientCompositionSet.minimum;

    expect(full.agents, isTrue);
    expect(full.conversation, isTrue);
    expect(full.targets, isTrue);
    expect(full.chrome, isTrue);
    expect(full.monitoring, isTrue);
    expect(full.agentHub, isTrue);
    expect(full.mobileRelay, isTrue);
    expect(full.models, isTrue);
    expect(full.pluginManagement, isTrue);
    expect(full.search, isTrue);
    expect(full.settings, isTrue);
    expect(full.skillHub, isTrue);
    expect(full.agentHub && !minimum.agentHub, isTrue);
    expect(full.mobileRelay && !minimum.mobileRelay, isTrue);
    expect(full.models && !minimum.models, isTrue);
    expect(full.pluginManagement && !minimum.pluginManagement, isTrue);
    expect(full.search && !minimum.search, isTrue);
    expect(full.settings && !minimum.settings, isTrue);
    expect(full.skillHub && !minimum.skillHub, isTrue);
  });

  test('every destination belongs to exactly one declared feature', () {
    for (final destination in ClientSection.values) {
      expect(
        ClientCompositionSet.full.isInstalled(destination),
        isTrue,
        reason: '$destination',
      );
      expect(
        ClientCompositionSet.minimum.isInstalled(destination),
        destination == ClientSection.agents ||
            destination == ClientSection.monitoring,
        reason: '$destination',
      );
    }
  });

  test('the catalogue projects the declaration it is given', () {
    final agentsOnly = ClientAppComposition(
      controller: ClientController(),
      compositionSet: const ClientCompositionSet(
        agents: true,
        conversation: true,
        targets: true,
        chrome: true,
        monitoring: false,
        agentHub: false,
        mobileRelay: false,
        models: false,
        pluginManagement: false,
        search: false,
        settings: false,
        skillHub: false,
      ),
    );
    addTearDown(agentsOnly.dispose);

    expect(agentsOnly.mountedDestinations.destinations, const [
      ClientSection.agents,
    ]);
    expect(agentsOnly.binding.navigation.current.destinations, const [
      ClientSection.agents,
    ]);
    expect(
      agentsOnly.binding.navigation.current.unavailable,
      isNot(contains(ClientSection.agents)),
      reason: 'the one declared capability is not reported absent',
    );
  });
}
