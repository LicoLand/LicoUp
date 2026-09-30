import 'package:flutter/material.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/composition/built_in_layout_composition.dart';
import 'package:licoup/src/composition/project_collaboration_root.dart';
import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/environment/workspace_home_directory_scope.dart';
import 'package:licoup/src/frontend/features/agent_hub/ui/agent_hub_panel.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_usage_panel.dart';
import 'package:licoup/src/frontend/features/agents/ui/agents_canvas.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_agents_home.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_pairing_channels.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_relay_panel.dart';
import 'package:licoup/src/frontend/features/models/ui/models_panel.dart';
import 'package:licoup/src/frontend/features/plugin_management/ui/adapter_plugin_panel.dart';
import 'package:licoup/src/frontend/features/settings/ui/settings_panel.dart';
import 'package:licoup/src/frontend/features/skill_hub/ui/skill_hub_panel.dart';
import 'package:licoup/src/frontend/layout/layout_scope.dart';
import 'package:licoup/src/frontend/layout/layout_state_port.dart';
import 'package:licoup/src/frontend/layout/layout_value_builder.dart';
import 'package:licoup/src/presentation/agent_hub/agent_hub_binding.dart';
import 'package:licoup/src/presentation/agents/agents_binding.dart';
import 'package:licoup/src/presentation/conversation/conversation_binding.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_binding.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_effect.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_intent.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_projection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/presentation/models/models_binding.dart';
import 'package:licoup/src/presentation/monitoring/monitoring_binding.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_binding.dart';
import 'package:licoup/src/presentation/settings/settings_binding.dart';
import 'package:licoup/src/presentation/shell/shell_intent.dart';
import 'package:licoup/src/presentation/skill_hub/skill_hub_binding.dart';
import 'package:licoup/src/presentation/targets/targets_binding.dart';

typedef ExternalUriOpener = Future<void> Function(Uri uri);

/// Resolves each shell destination against the bindings the composition
/// installed.
///
/// A destination whose feature was not installed has no binding here, and an
/// absent binding renders an empty surface: the shell neither throws, nor logs
/// a fallback, nor substitutes another feature's panel. A destination whose
/// binding is present renders exactly the panel it rendered before this
/// boundary existed.
///
/// The agents destination is the one exception, because the minimum
/// composition always serves it and the conversation workspace requires a
/// relay value: an absent relay feature contributes its absent value
/// ([_absentMobileRelayBinding]) rather than a null parameter.
final class ShellDestinations {
  const ShellDestinations({
    required this.layout,
    required this.shellIntents,
    required this.agents,
    required this.conversation,
    required this.monitoring,
    required this.mobileRelay,
    required this.targets,
    required this.openExternalUri,
    required this.workspaceHomeDirectory,
    this.skillHub,
    this.pluginManagement,
    this.models,
    this.settings,
    this.agentHub,
  });

  final BuiltInLayoutComposition layout;
  final IntentSink<ShellIntent> shellIntents;
  final AgentsBinding agents;
  final ConversationBinding conversation;
  final MonitoringBinding monitoring;
  final MobileRelayBinding? mobileRelay;
  final TargetsBinding targets;
  final ExternalUriOpener openExternalUri;
  final String workspaceHomeDirectory;

  /// The optional feature bindings. Null means the composition did not install
  /// that feature, so its destination has no surface.
  final SkillHubBinding? skillHub;
  final PluginManagementBinding? pluginManagement;
  final ModelsBinding? models;
  final SettingsBinding? settings;
  final AgentHubBinding? agentHub;

  static const Widget _absent = SizedBox.shrink();

  GlobalKey createAgentsHomeKey() => GlobalKey<MobileAgentsHomeState>();

  void resetAgentsHome(GlobalKey agentsHomeKey) {
    final state = agentsHomeKey.currentState;
    if (state is MobileAgentsHomeState) state.resetToList();
  }

  Widget build(
    BuildContext context,
    ClientSection destination, {
    required GlobalKey agentsHomeKey,
  }) {
    switch (destination) {
      case ClientSection.agents:
        return WorkspaceHomeDirectoryScope(
          path: workspaceHomeDirectory,
          child: AgentsCanvas(
            agents: agents,
            conversation: conversation,
            relay: mobileRelay ?? _absentMobileRelayBinding,
            monitoring: monitoring,
            targets: targets,
            onSelectDestination: (destination) =>
                shellIntents.send(SelectShellDestination(destination)),
            agentsHomeKey: agentsHomeKey as GlobalKey<MobileAgentsHomeState>,
          ),
        );
      case ClientSection.monitoring:
        return AgentUsagePanel(binding: monitoring);
      case ClientSection.skillHub:
        final skillHub = this.skillHub;
        if (skillHub == null) return _absent;
        return SkillHubPanel(binding: skillHub);
      case ClientSection.pluginManagement:
        final pluginManagement = this.pluginManagement;
        if (pluginManagement == null) return _absent;
        return AdapterPluginPanel(binding: pluginManagement);
      case ClientSection.mobileRelay:
        final mobileRelay = this.mobileRelay;
        final models = this.models;
        if (mobileRelay == null || models == null) return _absent;
        return MobileRelayPanel(
          binding: mobileRelay,
          chatChannels: MobilePairingChannels(binding: models),
        );
      case ClientSection.models:
        final models = this.models;
        if (models == null) return _absent;
        return ModelsPanel(binding: models, pane: ModelsPanelPane.gateway);
      case ClientSection.settings:
        final settings = this.settings;
        if (settings == null) return _absent;
        return SettingsPanel(
          binding: settings,
          layoutRegistry: layout.registry,
        );
      case ClientSection.agentHub:
        final agentHub = this.agentHub;
        if (agentHub == null) return _absent;
        return _FeatureDestinationHost(
          agentHub: AgentHubPanel(
            binding: agentHub,
            plugins: pluginManagement,
            skills: skillHub,
            openHomepage: openExternalUri,
            onOpenAgent: (agentId) =>
                shellIntents.send(OpenShellAgent(agentId)),
          ),
        );
    }
  }
}

/// The relay value the agents destination receives when the relay feature is
/// not installed.
///
/// [AgentsCanvas] requires a [MobileRelayBinding] because the conversation
/// workspace renders its remote-approval region from one. A minimum
/// composition that does not install the relay feature therefore has to hand
/// the workspace the feature's absent value instead of a null: no peers, no
/// approvals, no transfers, an idle ready phase, an intent sink that drops what
/// it cannot route, and an effect source that never emits. The substitute owns
/// no state, opens no source and starts no owner, so the uninstalled feature
/// still has no background owner and no surface of its own.
final MobileRelayBinding _absentMobileRelayBinding = MobileRelayBinding(
  projection: _AbsentMobileRelayProjection(),
  intents: const _DroppedMobileRelayIntents(),
  effects: const _IdleMobileRelayEffects(),
);

final MobileRelayProjection _absentMobileRelayProjectionValue =
    MobileRelayProjection(
      peers: const <RelayPeerProjection>[],
      approvals: const <RelayApprovalProjection>[],
      transfers: const <RelayTransferProjection>[],
      pairingCode: '',
      stationLabel: '',
      phase: PresentationPhase.ready,
    );

final class _AbsentMobileRelayProjection
    implements ProjectionSource<MobileRelayProjection> {
  @override
  MobileRelayProjection get current => _absentMobileRelayProjectionValue;

  @override
  Stream<ProjectionUpdate<MobileRelayProjection>> get changes =>
      const Stream.empty();
}

final class _DroppedMobileRelayIntents
    implements IntentSink<MobileRelayIntent> {
  const _DroppedMobileRelayIntents();

  @override
  void send(MobileRelayIntent intent) {}
}

final class _IdleMobileRelayEffects implements EffectSource<MobileRelayEffect> {
  const _IdleMobileRelayEffects();

  @override
  Stream<MobileRelayEffect> get effects => const Stream.empty();
}

/// Both feature entries use the existing retained feature host. Layouts decide
/// where that host sits; it never replaces the permanent conversation surface.
final class _FeatureDestinationHost extends StatelessWidget {
  const _FeatureDestinationHost({required this.agentHub});

  final Widget agentHub;

  @override
  Widget build(BuildContext context) {
    final state = LayoutScope.maybeOf(context)?.state;
    int selection() {
      final tab = state?.readIfDeclaredFor(
        ClientSection.agentHub,
        LayoutStateChannels.featureSection,
      );
      return tab is LayoutTabState && tab.index == 1 ? 1 : 0;
    }

    return LayoutValuesBuilder(
      state: state,
      valuesOf: (_) => [selection()],
      builder: (context) => selection() == 1
          ? KeyedSubtree(
              key: const ValueKey('project-swimlanes-feature-content'),
              child: ProjectCollaborationRoot.layerOf(context),
            )
          : agentHub,
    );
  }
}
