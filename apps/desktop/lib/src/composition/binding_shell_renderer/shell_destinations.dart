import 'package:flutter/material.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/composition/built_in_layout_composition.dart';
import 'package:licoup/src/composition/client_composition_set.dart';
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
import 'package:licoup/src/presentation/agent_hub/agent_hub_binding.dart';
import 'package:licoup/src/presentation/agents/agents_binding.dart';
import 'package:licoup/src/presentation/conversation/conversation_binding.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_binding.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_effect.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_intent.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_projection.dart';
import 'package:licoup/src/presentation/models/models_binding.dart';
import 'package:licoup/src/presentation/monitoring/monitoring_binding.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_binding.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/presentation/settings/settings_binding.dart';
import 'package:licoup/src/presentation/shell/shell_intent.dart';
import 'package:licoup/src/presentation/skill_hub/skill_hub_binding.dart';
import 'package:licoup/src/presentation/targets/targets_binding.dart';

typedef ExternalUriOpener = Future<void> Function(Uri uri);

/// Resolves each shell destination against the composition declaration and the
/// bindings the composition installed.
///
/// This owner replaces the hardcoded section switch that used to sit in the
/// renderer: the destination-to-surface decision lives here, next to the
/// declaration that decides which features exist, and the renderer only
/// forwards.
///
/// A destination whose feature the composition did not declare has no binding
/// here, and no binding renders an empty surface: the shell neither throws, nor
/// logs a fallback, nor substitutes another feature's panel. A destination
/// whose binding is present renders exactly the panel it rendered before this
/// boundary existed.
///
/// The agents destination is the one exception, because the minimum
/// composition always serves it and the conversation workspace requires a
/// relay value: an absent relay feature contributes its absent value
/// ([_absentMobileRelayBinding]) rather than a null parameter.
final class ShellDestinations {
  const ShellDestinations({
    required this.composition,
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

  /// The declaration this resolver answers to. A destination is served only
  /// when its feature composition is named here.
  final ClientCompositionSet composition;

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

  /// The surface an undeclared feature projects: nothing at all.
  static const Widget absentSurface = SizedBox.shrink();

  GlobalKey createAgentsHomeKey() => GlobalKey<MobileAgentsHomeState>();

  /// Whether the binding the composition installed matches what the
  /// declaration promises for [destination].
  ///
  /// A declared capability must carry its binding and an absent one must carry
  /// none, so this assertion catches a factory that forgets to pass a binding
  /// or passes one for a feature it did not declare. It never gates runtime
  /// behavior: absence is decided by the declaration alone.
  bool _bindingsAgree(ClientSection destination, bool installed) =>
      switch (destination) {
        ClientSection.agents => true,
        ClientSection.monitoring => true,
        ClientSection.skillHub => (skillHub != null) == installed,
        ClientSection.pluginManagement =>
          (pluginManagement != null) == installed,
        ClientSection.mobileRelay => (mobileRelay != null) == installed,
        ClientSection.models => (models != null) == installed,
        ClientSection.settings => (settings != null) == installed,
        ClientSection.agentHub => (agentHub != null) == installed,
      };

  void resetAgentsHome(GlobalKey agentsHomeKey) {
    final state = agentsHomeKey.currentState;
    if (state is MobileAgentsHomeState) state.resetToList();
  }

  Widget build(
    BuildContext context,
    ClientSection destination, {
    required GlobalKey agentsHomeKey,
  }) {
    final installed = composition.isInstalled(destination);
    assert(
      _bindingsAgree(destination, installed),
      'destination binding disagrees with the composition declaration: '
      '$destination is ${installed ? 'declared' : 'absent'} but its binding is '
      '${installed ? 'missing' : 'installed'}',
    );
    switch (destination) {
      case ClientSection.agents:
        if (!installed) return absentSurface;
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
        if (!installed) return absentSurface;
        return AgentUsagePanel(binding: monitoring);
      case ClientSection.skillHub:
        final skillHub = this.skillHub;
        if (!installed || skillHub == null) return absentSurface;
        return SkillHubPanel(binding: skillHub);
      case ClientSection.pluginManagement:
        final pluginManagement = this.pluginManagement;
        if (!installed || pluginManagement == null) return absentSurface;
        return AdapterPluginPanel(binding: pluginManagement);
      case ClientSection.mobileRelay:
        final mobileRelay = this.mobileRelay;
        final models = this.models;
        if (!installed || mobileRelay == null || models == null) {
          return absentSurface;
        }
        return MobileRelayPanel(
          binding: mobileRelay,
          chatChannels: MobilePairingChannels(binding: models),
        );
      case ClientSection.models:
        final models = this.models;
        if (!installed || models == null) return absentSurface;
        return ModelsPanel(binding: models, pane: ModelsPanelPane.gateway);
      case ClientSection.settings:
        final settings = this.settings;
        if (!installed || settings == null) return absentSurface;
        return SettingsPanel(
          binding: settings,
          layoutRegistry: layout.registry,
        );
      case ClientSection.agentHub:
        final agentHub = this.agentHub;
        if (!installed || agentHub == null) return absentSurface;
        return AgentHubPanel(
          binding: agentHub,
          plugins: pluginManagement,
          skills: skillHub,
          openHomepage: openExternalUri,
          onOpenAgent: (agentId) => shellIntents.send(OpenShellAgent(agentId)),
        );
    }
  }
}

/// The relay value the agents destination receives when the relay feature is
/// not installed.
///
/// [AgentsCanvas] requires a [MobileRelayBinding] because the conversation
/// workspace renders its remote-approval region from one. A composition that
/// does not install the relay feature therefore has to hand the workspace the
/// feature's absent value instead of a null: no peers, no approvals, no
/// transfers, an idle ready phase, an intent sink that drops what it cannot
/// route, and an effect source that never emits. The substitute owns no state,
/// opens no source and starts no owner, so the uninstalled feature still has no
/// background owner and no surface of its own.
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
