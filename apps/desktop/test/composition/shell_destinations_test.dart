import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/composition/binding_shell_renderer/shell_destinations.dart';
import 'package:licoup/src/composition/client_app_composition.dart';
import 'package:licoup/src/composition/client_composition_set.dart';
import 'package:licoup/src/composition/client_feature_mounts.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/features/agent_hub/ui/agent_hub_panel.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_usage_panel.dart';
import 'package:licoup/src/frontend/environment/workspace_home_directory_scope.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_relay_panel.dart';
import 'package:licoup/src/frontend/features/models/ui/models_panel.dart';
import 'package:licoup/src/frontend/features/plugin_management/ui/adapter_plugin_panel.dart';
import 'package:licoup/src/frontend/features/settings/ui/settings_panel.dart';
import 'package:licoup/src/frontend/features/skill_hub/ui/skill_hub_panel.dart';
import 'package:licoup/src/presentation/shell/shell_intent.dart';

/// The resolver answers the mount directory, so every case here drives
/// [ShellDestinations.build] with a declaration and asserts only which surface
/// that declaration produces. The expected surface of each destination is a
/// table of expectations, never a dispatch the resolver could fall back to.
const List<ClientSection> _optionalDestinations = <ClientSection>[
  ClientSection.skillHub,
  ClientSection.pluginManagement,
  ClientSection.mobileRelay,
  ClientSection.models,
  ClientSection.settings,
  ClientSection.agentHub,
];

/// The declaration that mounts exactly the features named by [enabled].
ClientCompositionSet _declaration(Iterable<FeatureMountId> enabled) {
  final mounted = Set<FeatureMountId>.of(enabled);
  return ClientCompositionSet.fromRequests(<FeatureMountRequest>[
    for (final request in ClientFeatureMounts.full)
      mounted.contains(request.id) ? request : request.unmounted(),
  ]);
}

void main() {
  testWidgets('an undeclared capability renders no surface at all', (
    tester,
  ) async {
    final composition = ClientAppComposition(
      controller: ClientController(),
      compositionSet: ClientCompositionSet.minimum,
    );
    addTearDown(composition.dispose);
    final destinations = composition.shellDestinations;

    await tester.pumpWidget(const SizedBox());
    final context = tester.element(find.byType(SizedBox));

    for (final destination in ClientSection.values) {
      final widget = destinations.build(
        context,
        destination,
        agentsHomeKey: destinations.createAgentsHomeKey(),
      );
      if (destination == ClientSection.agents) {
        expect(
          widget,
          isA<WorkspaceHomeDirectoryScope>(),
          reason: 'agents is mounted',
        );
      } else if (destination == ClientSection.monitoring) {
        expect(widget, isA<AgentUsagePanel>());
      } else {
        expect(
          widget,
          same(ShellDestinations.absentSurface),
          reason: '$destination has no mounted feature',
        );
      }
    }
  });

  testWidgets('a mounted capability renders exactly its own panel', (
    tester,
  ) async {
    final composition = ClientAppComposition(controller: ClientController());
    addTearDown(composition.dispose);
    final destinations = composition.shellDestinations;

    await tester.pumpWidget(const SizedBox());
    final context = tester.element(find.byType(SizedBox));
    Widget build(ClientSection destination) => destinations.build(
      context,
      destination,
      agentsHomeKey: destinations.createAgentsHomeKey(),
    );

    expect(build(ClientSection.agents), isA<WorkspaceHomeDirectoryScope>());
    expect(build(ClientSection.monitoring), isA<AgentUsagePanel>());
    expect(build(ClientSection.skillHub), isA<SkillHubPanel>());
    expect(build(ClientSection.pluginManagement), isA<AdapterPluginPanel>());
    expect(build(ClientSection.mobileRelay), isA<MobileRelayPanel>());
    expect(build(ClientSection.models), isA<ModelsPanel>());
    expect(build(ClientSection.settings), isA<SettingsPanel>());
    expect(build(ClientSection.agentHub), isA<AgentHubPanel>());
  });

  testWidgets(
    'mounting and unmounting a declaration changes only its own destination',
    (tester) async {
      final withoutModels = ClientAppComposition(
        controller: ClientController(),
        compositionSet: ClientCompositionSet.minimum,
      );
      final withModels = ClientAppComposition(
        controller: ClientController(),
        compositionSet: _declaration(<FeatureMountId>{
          ClientFeatureMounts.agents.id,
          ClientFeatureMounts.conversation.id,
          ClientFeatureMounts.targets.id,
          ClientFeatureMounts.chrome.id,
          ClientFeatureMounts.monitoring.id,
          ClientFeatureMounts.models.id,
        }),
      );
      addTearDown(withoutModels.dispose);
      addTearDown(withModels.dispose);

      await tester.pumpWidget(const SizedBox());
      final context = tester.element(find.byType(SizedBox));

      Widget surface(ClientAppComposition composition, ClientSection section) =>
          composition.shellDestinations.build(
            context,
            section,
            agentsHomeKey: composition.shellDestinations.createAgentsHomeKey(),
          );

      // The minimum declaration leaves the models mount unmounted: the entry is
      // still declared, and the phase alone decides that it contributes
      // nothing.
      expect(
        withoutModels.compositionSet.phaseOf(ClientFeatureMounts.models.id),
        FeatureMountPhase.unmounted,
      );
      expect(
        withoutModels.compositionSet.mounts.entryFor(
          ClientFeatureMounts.models.id,
        ),
        isNotNull,
      );
      expect(
        withoutModels.mountedDestinations.isMounted(ClientSection.models),
        isFalse,
      );
      expect(
        surface(withoutModels, ClientSection.models),
        same(ShellDestinations.absentSurface),
      );
      expect(
        surface(withoutModels, ClientSection.agents),
        isA<WorkspaceHomeDirectoryScope>(),
      );
      expect(
        surface(withoutModels, ClientSection.monitoring),
        isA<AgentUsagePanel>(),
      );

      // Enabling it: the mount changes its own phase, its own binding and its
      // own destination, and nothing else.
      expect(
        withModels.compositionSet.phaseOf(ClientFeatureMounts.models.id),
        FeatureMountPhase.enabled,
      );
      expect(
        withModels.mountedDestinations.isMounted(ClientSection.models),
        isTrue,
      );
      expect(surface(withModels, ClientSection.models), isA<ModelsPanel>());
      expect(
        surface(withModels, ClientSection.agents),
        isA<WorkspaceHomeDirectoryScope>(),
        reason: 'the mount that was present before is still present',
      );
      for (final section in _optionalDestinations) {
        if (section == ClientSection.models) continue;
        expect(
          surface(withModels, section),
          same(ShellDestinations.absentSurface),
          reason: 'only models changed; $section is still absent',
        );
      }
    },
  );

  testWidgets('the shell navigation plane reports the unmounted capabilities', (
    tester,
  ) async {
    final composition = ClientAppComposition(
      controller: ClientController(),
      compositionSet: ClientCompositionSet.minimum,
    );
    addTearDown(composition.dispose);

    final navigation = composition.binding.navigation.current;
    expect(navigation.destinations, const [
      ClientSection.agents,
      ClientSection.monitoring,
    ]);
    expect(navigation.destination, ClientSection.agents);
    expect(navigation.recoveryDestination, isNull);
    expect(navigation.unavailable, _optionalDestinations);
  });

  test(
    'a restored view naming an unmounted capability recovers to a mount',
    () {
      final composition = ClientAppComposition(
        controller: ClientController(),
        compositionSet: ClientCompositionSet.minimum,
      );
      addTearDown(composition.dispose);

      composition.binding.intents.send(
        const SelectShellDestination(ClientSection.settings),
      );

      final navigation = composition.binding.navigation.current;
      expect(navigation.destination, ClientSection.agents);
      expect(navigation.recoveryDestination, ClientSection.agents);
      expect(
        navigation.destinations,
        isNot(contains(ClientSection.settings)),
        reason: 'an unmounted capability is never offered as a selection',
      );
    },
  );
}
