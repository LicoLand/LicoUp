import 'package:flutter/material.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/composition/built_in_layout_composition.dart';
import 'package:licoup/src/composition/client_composition_set.dart';
import 'package:licoup/src/composition/client_feature_mounts.dart';
import 'package:licoup/src/contracts/client_update_models.dart';
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
import 'package:licoup/src/frontend/projects/project_plan_submission.dart';
import 'package:licoup/src/frontend/projects/projects_canvas_panel.dart';
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
import 'package:licoup/src/presentation/projects/projects_binding.dart';
import 'package:licoup/src/presentation/settings/settings_binding.dart';
import 'package:licoup/src/presentation/shell/shell_intent.dart';
import 'package:licoup/src/presentation/skill_hub/skill_hub_binding.dart';
import 'package:licoup/src/presentation/targets/targets_binding.dart';

typedef ExternalUriOpener = Future<void> Function(Uri uri);

/// The bindings one mounted feature's surface is built from.
///
/// The composition boundary fills this value from exactly the bindings it
/// installed, so a mount whose feature is not enabled finds nothing to render
/// with. Only the shell's own bindings are non-nullable: an optional feature
/// contributes its binding when its mount is enabled and nothing when it is
/// not, which is what keeps an absent feature from rendering another feature's
/// panel.
final class ClientFeatureSurface {
  const ClientFeatureSurface({
    required this.layout,
    required this.shellIntents,
    required this.agents,
    required this.conversation,
    required this.monitoring,
    required this.mobileRelay,
    required this.targets,
    required this.models,
    required this.skillHub,
    required this.pluginManagement,
    required this.settings,
    required this.agentHub,
    required this.openExternalUri,
    required this.workspaceHomeDirectory,
    required this.clientUpdateAdmission,
    this.projects,
    this.projectPlanSubmission = const UnconvertedProjectPlan(),
  });

  final BuiltInLayoutComposition layout;
  final IntentSink<ShellIntent> shellIntents;
  final AgentsBinding agents;
  final ConversationBinding conversation;
  final MonitoringBinding monitoring;
  final MobileRelayBinding? mobileRelay;
  final TargetsBinding targets;
  final ModelsBinding? models;
  final SkillHubBinding? skillHub;
  final PluginManagementBinding? pluginManagement;
  final SettingsBinding? settings;
  final AgentHubBinding? agentHub;
  final ExternalUriOpener openExternalUri;
  final String workspaceHomeDirectory;

  /// The project canvas binding, present exactly while the projects mount is
  /// enabled.
  ///
  /// The canvas is a region rather than a destination: it presents the durable
  /// project facts and the local arrangement this client read, and the surface
  /// that hosts it reads the binding from here.
  final ProjectsBinding? projects;

  /// The caller-converted plan document the canvas may submit, or none.
  ///
  /// A plan arrives only as a caller-converted canonical document: this field
  /// carries that document and never a source, a directory or a conversion.
  /// The composition root supplies it; a client without an importer keeps the
  /// explicit [UnconvertedProjectPlan] and the canvas states the rule.
  final ProjectPlanSubmission projectPlanSubmission;

  /// Live read of the host maintenance answer the settings surface renders its
  /// upgrade actions from. The composition supplies the application controller
  /// read; the renderer's fail-closed default reaches here unchanged.
  final ClientUpdateAdmission Function() clientUpdateAdmission;
}

/// How one feature builds the surface of a destination it contributes.
///
/// A factory answers null when it cannot build its surface at all: the mount's
/// own binding is not installed, or the destination is not this feature's to
/// serve. Null is never another feature's surface.
typedef ClientFeatureSurfaceFactory =
    Widget? Function(
      BuildContext context,
      ClientFeatureSurface surface,
      GlobalKey agentsHomeKey,
    );

/// One feature's entry in the client's mount catalogue.
///
/// The entry pairs the feature's own directory declaration — its identity, the
/// destinations and capabilities it contributes, and the phase the composition
/// declared — with the surface this client compiled for it. A feature that
/// contributes no destination has no surface factory; a feature whose surface
/// needs another mount's capability names it in [requires].
final class ClientFeatureMount {
  const ClientFeatureMount({
    required this.id,
    this.requires = const <MountCapabilityId>{},
    this.surface,
  });

  final FeatureMountId id;

  /// Capabilities this surface cannot be built without.
  ///
  /// The catalogue serves the surface only while the directory still
  /// contributes every one of them, so a mount whose dependency another
  /// declaration stopped contributing fails closed instead of rendering from a
  /// binding that is no longer installed.
  final Set<MountCapabilityId> requires;

  /// The surface this client compiled for [id], or null when the feature
  /// contributes no destination of its own.
  final ClientFeatureSurfaceFactory? surface;

  @override
  String toString() => 'ClientFeatureMount($id)';
}

/// The client's feature mount catalogue: what every feature contributes and how
/// its surface is built.
///
/// The catalogue owns no dispatch of its own. A destination is resolved by
/// asking the directory which entry contributes it and then asking that entry
/// for its surface, so the shell renderer names no destination and no feature:
/// removing a declaration from the directory removes the destination, the
/// capability and the surface together.
final class ClientFeatureCatalogue {
  /// Assembles the catalogue the composition declaration and the installed
  /// bindings describe.
  factory ClientFeatureCatalogue.of({
    required ClientCompositionSet composition,
    required ClientFeatureSurface bindings,
  }) {
    final mounts = <ClientFeatureMount>[
      ClientFeatureMount(
        id: ClientFeatureMounts.agents.id,
        surface: (context, surface, agentsHomeKey) =>
            WorkspaceHomeDirectoryScope(
              path: surface.workspaceHomeDirectory,
              child: AgentsCanvas(
                agents: surface.agents,
                conversation: surface.conversation,
                relay: surface.mobileRelay ?? _absentMobileRelayBinding,
                monitoring: surface.monitoring,
                targets: surface.targets,
                onSelectDestination: (destination) => surface.shellIntents.send(
                  SelectShellDestination(destination),
                ),
                agentsHomeKey:
                    agentsHomeKey as GlobalKey<MobileAgentsHomeState>,
              ),
            ),
      ),
      ClientFeatureMount(
        id: ClientFeatureMounts.monitoring.id,
        surface: (context, surface, agentsHomeKey) =>
            AgentUsagePanel(binding: surface.monitoring),
      ),
      ClientFeatureMount(
        id: ClientFeatureMounts.skillHub.id,
        surface: (context, surface, agentsHomeKey) {
          final skillHub = surface.skillHub;
          return skillHub == null ? null : SkillHubPanel(binding: skillHub);
        },
      ),
      ClientFeatureMount(
        id: ClientFeatureMounts.pluginManagement.id,
        surface: (context, surface, agentsHomeKey) {
          final pluginManagement = surface.pluginManagement;
          return pluginManagement == null
              ? null
              : AdapterPluginPanel(binding: pluginManagement);
        },
      ),
      ClientFeatureMount(
        id: ClientFeatureMounts.mobileRelay.id,
        requires: <MountCapabilityId>{ClientCapabilities.modelCatalogue},
        surface: (context, surface, agentsHomeKey) {
          final mobileRelay = surface.mobileRelay;
          final models = surface.models;
          if (mobileRelay == null || models == null) return null;
          return MobileRelayPanel(
            binding: mobileRelay,
            chatChannels: MobilePairingChannels(binding: models),
          );
        },
      ),
      ClientFeatureMount(
        id: ClientFeatureMounts.models.id,
        surface: (context, surface, agentsHomeKey) {
          final models = surface.models;
          return models == null
              ? null
              : ModelsPanel(binding: models, pane: ModelsPanelPane.gateway);
        },
      ),
      ClientFeatureMount(
        id: ClientFeatureMounts.settings.id,
        surface: (context, surface, agentsHomeKey) {
          final settings = surface.settings;
          return settings == null
              ? null
              : SettingsPanel(
                  binding: settings,
                  layoutRegistry: surface.layout.registry,
                  clientUpdateAdmission: surface.clientUpdateAdmission,
                );
        },
      ),
      ClientFeatureMount(
        id: ClientFeatureMounts.agentHub.id,
        surface: (context, surface, agentsHomeKey) {
          final agentHub = surface.agentHub;
          return agentHub == null
              ? null
              : AgentHubPanel(
                  binding: agentHub,
                  plugins: surface.pluginManagement,
                  skills: surface.skillHub,
                  openHomepage: surface.openExternalUri,
                  onOpenAgent: (agentId) =>
                      surface.shellIntents.send(OpenShellAgent(agentId)),
                );
        },
      ),
      ClientFeatureMount(
        id: ClientFeatureMounts.projects.id,
        // The canvas compiles its surface here. The mount contributes a
        // capability and no destination, so the entry is reached by the shell
        // surface that hosts the region: no shell destination exists for a
        // canvas, and the client's destination set is asserted, so this
        // composition does not invent one.
        surface: (context, surface, agentsHomeKey) {
          final projects = surface.projects;
          return projects == null
              ? null
              : ProjectsCanvasPanel(
                  binding: projects,
                  submission: surface.projectPlanSubmission,
                );
        },
      ),
    ];
    return ClientFeatureCatalogue._(
      composition: composition,
      surface: bindings,
      // The catalogue is the directory's own projection: a feature the
      // declaration does not hold has no entry here either, so no surface can
      // be reached for a mount the directory does not own.
      mounts: List<ClientFeatureMount>.unmodifiable(<ClientFeatureMount>[
        for (final mount in mounts)
          if (composition.mounts.entryFor(mount.id) != null) mount,
      ]),
    );
  }

  ClientFeatureCatalogue._({
    required this.composition,
    required this.surface,
    required this.mounts,
  }) {
    _assertSurfaceCoverage();
    _assertBindingsAgree();
  }

  /// The declaration naming every feature composition this client owns.
  final ClientCompositionSet composition;

  /// The bindings the features' surfaces are built from.
  final ClientFeatureSurface surface;

  /// Every declared feature's entry, in directory order.
  ///
  /// A feature the declaration does not hold has no entry, so it contributes no
  /// surface even if this client compiles one for it.
  final List<ClientFeatureMount> mounts;

  /// The directory of feature mounts this client owns.
  ///
  /// The composition declaration is the directory: its entries are the mounts,
  /// their phases are the lifecycle state, and the destinations and
  /// capabilities they contribute are their own declarations.
  FeatureMountDirectory get directory => composition.mounts;

  ClientFeatureMount? mountForId(FeatureMountId id) {
    for (final mount in mounts) {
      if (mount.id == id) return mount;
    }
    return null;
  }

  /// The entry that contributes [destination] while it is enabled, or null when
  /// no enabled entry contributes it.
  ClientFeatureMount? mountForDestination(MountDestinationId destination) {
    final contributor = directory.contributorOf(destination);
    return contributor == null ? null : mountForId(contributor.id);
  }

  /// Whether every capability [mount] requires is still contributed.
  bool serves(ClientFeatureMount mount) =>
      directory.contributesCapabilities(mount.requires);

  /// The surface [destination] projects, or null when nothing this client
  /// mounts contributes it.
  ///
  /// Null is the only answer an absent capability gets: no other feature's
  /// surface is substituted, no fallback is logged, and the directory is what
  /// decided.
  Widget? buildSurface(
    BuildContext context,
    MountDestinationId destination, {
    required GlobalKey agentsHomeKey,
  }) {
    final mount = mountForDestination(destination);
    if (mount == null || !serves(mount)) return null;
    final factory = mount.surface;
    return factory?.call(context, surface, agentsHomeKey);
  }

  /// A mounted feature that contributes a destination must have a surface this
  /// client compiled, or the destination would be offered with nothing to show.
  void _assertSurfaceCoverage() {
    for (final entry in directory.mounts) {
      if (!entry.isEnabled || entry.destinations.isEmpty) continue;
      assert(
        mountForId(entry.id)?.surface != null,
        'mounted feature ${entry.id} contributes ${entry.destinations} but the '
        'client compiles no surface for it',
      );
    }
  }

  /// An optional capability's binding is installed exactly when its mount is
  /// enabled, so this catches a factory that forgets a binding or passes one for
  /// a feature the declaration does not mount. It never decides behavior:
  /// absence is decided by the directory alone.
  ///
  /// The shell's own bindings ([ClientFeatureSurface.agents],
  /// [ClientFeatureSurface.conversation], [ClientFeatureSurface.targets],
  /// [ClientFeatureSurface.monitoring]) are not part of this check because the
  /// composition always constructs them; only the optional mounts hand the
  /// renderer a null when their declaration leaves them out.
  void _assertBindingsAgree() {
    _assertAgrees(ClientFeatureMounts.agentHub.id, surface.agentHub);
    _assertAgrees(ClientFeatureMounts.mobileRelay.id, surface.mobileRelay);
    _assertAgrees(ClientFeatureMounts.models.id, surface.models);
    _assertAgrees(
      ClientFeatureMounts.pluginManagement.id,
      surface.pluginManagement,
    );
    _assertAgrees(ClientFeatureMounts.settings.id, surface.settings);
    _assertAgrees(ClientFeatureMounts.skillHub.id, surface.skillHub);
    _assertAgrees(ClientFeatureMounts.projects.id, surface.projects);
  }

  void _assertAgrees(FeatureMountId id, Object? binding) {
    final installed = directory.isEnabled(id);
    assert(
      (binding != null) == installed,
      'feature $id is ${installed ? 'mounted' : 'absent'} but its binding is '
      '${installed ? 'missing' : 'installed'}',
    );
  }
}

/// The relay value the agents surface receives when the relay feature is not
/// mounted.
///
/// [AgentsCanvas] requires a [MobileRelayBinding] because the conversation
/// workspace renders its remote-approval region from one. A composition that
/// does not mount the relay therefore has to hand the workspace the feature's
/// absent value instead of a null: no peers, no approvals, no transfers, an
/// idle ready phase, an intent sink that drops what it cannot route, and an
/// effect source that never emits. The substitute owns no state, opens no
/// source and starts no owner, so the unmounted feature still has no background
/// owner and no surface of its own.
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
