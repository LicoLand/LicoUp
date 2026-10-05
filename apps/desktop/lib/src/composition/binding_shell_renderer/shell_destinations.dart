import 'package:flutter/material.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/composition/built_in_layout_composition.dart';
import 'package:licoup/src/composition/client_composition_set.dart';
import 'package:licoup/src/composition/client_feature_catalogue.dart';
import 'package:licoup/src/composition/client_feature_mounts.dart';
import 'package:licoup/src/contracts/client_update_models.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_agents_home.dart';
import 'package:licoup/src/frontend/projects/project_plan_submission.dart';
import 'package:licoup/src/presentation/agent_hub/agent_hub_binding.dart';
import 'package:licoup/src/presentation/agents/agents_binding.dart';
import 'package:licoup/src/presentation/conversation/conversation_binding.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_binding.dart';
import 'package:licoup/src/presentation/models/models_binding.dart';
import 'package:licoup/src/presentation/monitoring/monitoring_binding.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_binding.dart';
import 'package:licoup/src/presentation/projects/projects_binding.dart';
import 'package:licoup/src/presentation/settings/settings_binding.dart';
import 'package:licoup/src/presentation/shell/shell_intent.dart';
import 'package:licoup/src/presentation/skill_hub/skill_hub_binding.dart';
import 'package:licoup/src/presentation/targets/targets_binding.dart';

/// Resolves each shell destination against the client's mount directory.
///
/// This owner names no destination and no feature. It asks the catalogue which
/// mounted entry contributes the requested destination and renders that entry's
/// own surface; a destination no enabled entry contributes, and a surface whose
/// mount requires a capability the directory no longer contributes, project
/// [absentSurface]. The shell neither throws, nor logs a fallback, nor
/// substitutes another feature's panel: absence is decided by the directory
/// alone.
///
/// The destination-to-surface decision therefore lives in the feature mount
/// catalogue, next to the declaration that decides which features exist, and the
/// renderer only forwards.
final class ShellDestinations {
  factory ShellDestinations({
    required ClientCompositionSet composition,
    required BuiltInLayoutComposition layout,
    required IntentSink<ShellIntent> shellIntents,
    required AgentsBinding agents,
    required ConversationBinding conversation,
    required MonitoringBinding monitoring,
    required MobileRelayBinding? mobileRelay,
    required TargetsBinding targets,
    required ExternalUriOpener openExternalUri,
    required String workspaceHomeDirectory,
    required ClientUpdateAdmission Function() clientUpdateAdmission,
    SkillHubBinding? skillHub,
    PluginManagementBinding? pluginManagement,
    ModelsBinding? models,
    SettingsBinding? settings,
    AgentHubBinding? agentHub,
    ProjectsBinding? projects,
    ProjectPlanSubmission projectPlanSubmission = const UnconvertedProjectPlan(),
  }) {
    final bindings = ClientFeatureSurface(
      layout: layout,
      shellIntents: shellIntents,
      agents: agents,
      conversation: conversation,
      monitoring: monitoring,
      mobileRelay: mobileRelay,
      targets: targets,
      models: models,
      skillHub: skillHub,
      pluginManagement: pluginManagement,
      settings: settings,
      agentHub: agentHub,
      openExternalUri: openExternalUri,
      workspaceHomeDirectory: workspaceHomeDirectory,
      clientUpdateAdmission: clientUpdateAdmission,
      projects: projects,
      projectPlanSubmission: projectPlanSubmission,
    );
    return ShellDestinations._(
      catalogue: ClientFeatureCatalogue.of(
        composition: composition,
        bindings: bindings,
      ),
      surface: bindings,
    );
  }

  const ShellDestinations._({required this.catalogue, required this.surface});

  /// The mount catalogue this resolver answers to.
  final ClientFeatureCatalogue catalogue;

  /// The bindings the mounted features' surfaces are built from.
  final ClientFeatureSurface surface;

  /// The declaration this resolver answers to. A destination is served only
  /// when an enabled mount of this directory contributes it.
  ClientCompositionSet get composition => catalogue.composition;

  /// The adapter plugin binding, for the chrome feature that must be reachable
  /// from every destination. Null means the composition did not mount it.
  PluginManagementBinding? get pluginManagement => surface.pluginManagement;

  /// The surface an undeclared feature projects: nothing at all.
  static const Widget absentSurface = SizedBox.shrink();

  GlobalKey createAgentsHomeKey() => GlobalKey<MobileAgentsHomeState>();

  void resetAgentsHome(GlobalKey agentsHomeKey) {
    final state = agentsHomeKey.currentState;
    if (state is MobileAgentsHomeState) state.resetToList();
  }

  Widget build(
    BuildContext context,
    ClientSection destination, {
    required GlobalKey agentsHomeKey,
  }) =>
      catalogue.buildSurface(
        context,
        mountDestinationOf(destination),
        agentsHomeKey: agentsHomeKey,
      ) ??
      absentSurface;
}
