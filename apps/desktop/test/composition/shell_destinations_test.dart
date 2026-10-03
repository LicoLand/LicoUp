import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/composition/binding_shell_renderer/shell_destinations.dart';
import 'package:licoup/src/composition/client_app_composition.dart';
import 'package:licoup/src/composition/client_composition_set.dart';
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

/// The destination owner is the seam this Task moved the section switch into.
/// Every case drives [ShellDestinations.build] directly, so each assertion is
/// about which surface a declaration produces and never about the layout host
/// that would eventually mount it.
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
      switch (destination) {
        case ClientSection.agents:
          expect(
            widget,
            isA<WorkspaceHomeDirectoryScope>(),
            reason: 'agents is declared',
          );
        case ClientSection.monitoring:
          expect(widget, isA<AgentUsagePanel>());
        case ClientSection.skillHub:
        case ClientSection.pluginManagement:
        case ClientSection.mobileRelay:
        case ClientSection.models:
        case ClientSection.settings:
        case ClientSection.agentHub:
          expect(
            widget,
            same(ShellDestinations.absentSurface),
            reason: '$destination has no declared feature',
          );
      }
    }
  });

  testWidgets('a declared capability renders exactly its own panel', (
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
    'installing and removing a synthetic capability changes only its mount',
    (tester) async {
      final withoutModels = ClientAppComposition(
        controller: ClientController(),
        compositionSet: ClientCompositionSet.minimum,
      );
      final withModels = ClientAppComposition(
        controller: ClientController(),
        compositionSet: const ClientCompositionSet(
          agents: true,
          conversation: true,
          targets: true,
          chrome: true,
          monitoring: true,
          agentHub: false,
          mobileRelay: false,
          models: true,
          pluginManagement: false,
          search: false,
          settings: false,
          skillHub: false,
        ),
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

      // Removing the capability: the declaration alone reports it absent, so
      // the destination projects no surface and every other mount is intact.
      expect(withoutModels.compositionSet.models, isFalse);
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

      // Installing it: the capability changes its own declaration field, its
      // own binding and its own destination, and nothing else.
      expect(withModels.compositionSet.models, isTrue);
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
      for (final section in const [
        ClientSection.skillHub,
        ClientSection.pluginManagement,
        ClientSection.mobileRelay,
        ClientSection.settings,
        ClientSection.agentHub,
      ]) {
        expect(
          surface(withModels, section),
          same(ShellDestinations.absentSurface),
          reason: 'only models changed; $section is still absent',
        );
      }
    },
  );

  testWidgets('the shell navigation plane reports the absent capabilities', (
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
    expect(navigation.unavailable, const [
      ClientSection.skillHub,
      ClientSection.pluginManagement,
      ClientSection.mobileRelay,
      ClientSection.models,
      ClientSection.settings,
      ClientSection.agentHub,
    ]);
  });

  test('a restored view naming an absent capability recovers to a mount', () {
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
      reason: 'an absent capability is never offered as a selection',
    );
  });
}
