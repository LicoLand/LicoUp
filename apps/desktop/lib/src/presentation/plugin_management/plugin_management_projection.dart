import 'package:licoup/src/application/features/plugin_management/models/package_center_catalog.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/contracts/optional_collaboration_local_server_models.dart';
import 'package:licoup/src/contracts/optional_collaboration_models.dart';
import 'package:licoup/src/contracts/optional_collaboration_workflow_models.dart';

final class PluginCapabilityProjection {
  const PluginCapabilityProjection({
    required this.id,
    required this.label,
    required this.detected,
    required this.running,
    this.pid,
    this.processName,
    this.port,
  });

  final String id;
  final String label;
  final bool detected;
  final bool running;
  final int? pid;
  final String? processName;
  final int? port;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PluginCapabilityProjection &&
          other.id == id &&
          other.label == label &&
          other.detected == detected &&
          other.running == running &&
          other.pid == pid &&
          other.processName == processName &&
          other.port == port;

  @override
  int get hashCode =>
      Object.hash(id, label, detected, running, pid, processName, port);
}

final class PluginEntryProjection {
  const PluginEntryProjection({
    required this.id,
    required this.label,
    required this.detail,
    required this.installationState,
    required this.installable,
    required this.uninstallable,
  });

  final String id;
  final String label;
  final String detail;
  final String installationState;
  final bool installable;
  final bool uninstallable;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PluginEntryProjection &&
          other.id == id &&
          other.label == label &&
          other.detail == detail &&
          other.installationState == installationState &&
          other.installable == installable &&
          other.uninstallable == uninstallable;

  @override
  int get hashCode => Object.hash(
    id,
    label,
    detail,
    installationState,
    installable,
    uninstallable,
  );
}

final class PluginProjectionItem {
  PluginProjectionItem({
    required this.id,
    required this.name,
    required this.description,
    required this.enabled,
    required this.installed,
    required this.installable,
    required this.uninstallable,
    required this.runtimeStateLabel,
    required this.protocolLabel,
    required this.packageId,
    required this.packageVersion,
    required this.facts,
    required this.agentInstallation,
    required Iterable<PluginCapabilityProjection> capabilities,
    Iterable<PluginEntryProjection> plugins = const [],
  }) : capabilities = immutablePresentationList(capabilities),
       plugins = immutablePresentationList(plugins);

  final String id;
  final String name;
  final String description;
  final bool enabled;
  final bool installed;
  final bool installable;
  final bool uninstallable;
  final String runtimeStateLabel;
  final String protocolLabel;

  /// The native package identity behind this entry, empty when the native
  /// package store holds no package for it.
  final String packageId;
  final String packageVersion;

  /// The four package facts the native store reported: available, installed,
  /// enabled and active. All four come from the native package catalogue — none
  /// is derived here.
  final PackageFactsProjection facts;

  /// Whether this entry's installation belongs to Agent Hub (third-party Agent
  /// installation) instead of the LicoUp package center.
  final bool agentInstallation;
  final List<PluginCapabilityProjection> capabilities;
  final List<PluginEntryProjection> plugins;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PluginProjectionItem &&
          other.id == id &&
          other.name == name &&
          other.description == description &&
          other.enabled == enabled &&
          other.installed == installed &&
          other.installable == installable &&
          other.uninstallable == uninstallable &&
          other.runtimeStateLabel == runtimeStateLabel &&
          other.protocolLabel == protocolLabel &&
          other.packageId == packageId &&
          other.packageVersion == packageVersion &&
          other.facts == facts &&
          other.agentInstallation == agentInstallation &&
          samePresentationList(other.capabilities, capabilities) &&
          samePresentationList(other.plugins, plugins);

  @override
  int get hashCode => Object.hash(
    id,
    name,
    description,
    enabled,
    installed,
    installable,
    uninstallable,
    runtimeStateLabel,
    protocolLabel,
    packageId,
    packageVersion,
    facts,
    agentInstallation,
    Object.hashAll(capabilities),
    Object.hashAll(plugins),
  );
}

/// One package the first-launch (or first-use) confirmation offers.
final class PackageRecommendationItemProjection {
  const PackageRecommendationItemProjection({
    required this.packageId,
    required this.label,
    required this.agentId,
    required this.archive,
  });

  final String packageId;
  final String label;
  final String agentId;
  final String archive;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PackageRecommendationItemProjection &&
          other.packageId == packageId &&
          other.label == label &&
          other.agentId == agentId &&
          other.archive == archive;

  @override
  int get hashCode => Object.hash(packageId, label, agentId, archive);
}

/// The one confirmation the package center shows for a recommended set.
final class PackageRecommendationProjection {
  PackageRecommendationProjection({
    required Iterable<PackageRecommendationItemProjection> recommendations,
    required this.firstLaunch,
  }) : recommendations = immutablePresentationList(recommendations);

  final List<PackageRecommendationItemProjection> recommendations;

  /// Whether this is the first launch of the data home instead of a capability
  /// that appeared later.
  final bool firstLaunch;

  bool get isEmpty => recommendations.isEmpty;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PackageRecommendationProjection &&
          samePresentationList(other.recommendations, recommendations) &&
          other.firstLaunch == firstLaunch;

  @override
  int get hashCode => Object.hash(firstLaunch, Object.hashAll(recommendations));
}

final class CollaborationProjection {
  CollaborationProjection({
    required this.statusLoaded,
    required this.enabled,
    required this.installed,
    required this.loaded,
    required this.runnerTrusted,
    required this.catalogLoaded,
    required this.phase,
    required Iterable<PresentationChoice> workflows,
    this.runtimeState,
    this.installPlan,
    this.workflowCatalog,
    this.localDeploymentPlan,
    this.mcpInstallPlan,
    Iterable<OptionalLocalServerState> localServers = const [],
    this.notice,
  }) : workflows = immutablePresentationList(workflows),
       localServers = immutablePresentationList(localServers);

  final bool statusLoaded;
  final bool enabled;
  final bool installed;
  final bool loaded;
  final bool runnerTrusted;
  final bool catalogLoaded;
  final PresentationPhase phase;
  final List<PresentationChoice> workflows;
  final OptionalCollaborationRuntimeState? runtimeState;
  final OptionalCollaborationInstallPlan? installPlan;
  final OptionalCollaborationWorkflowCatalog? workflowCatalog;
  final OptionalCollaborationWorkflowPlan? localDeploymentPlan;
  final OptionalCollaborationWorkflowPlan? mcpInstallPlan;
  final List<OptionalLocalServerState> localServers;
  final PresentationNotice? notice;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CollaborationProjection &&
          other.statusLoaded == statusLoaded &&
          other.enabled == enabled &&
          other.installed == installed &&
          other.loaded == loaded &&
          other.runnerTrusted == runnerTrusted &&
          other.catalogLoaded == catalogLoaded &&
          other.phase == phase &&
          samePresentationList(other.workflows, workflows) &&
          other.runtimeState == runtimeState &&
          other.installPlan == installPlan &&
          other.workflowCatalog == workflowCatalog &&
          other.localDeploymentPlan == localDeploymentPlan &&
          other.mcpInstallPlan == mcpInstallPlan &&
          samePresentationList(other.localServers, localServers) &&
          other.notice == notice;

  @override
  int get hashCode => Object.hash(
    statusLoaded,
    enabled,
    installed,
    loaded,
    runnerTrusted,
    catalogLoaded,
    phase,
    Object.hashAll(workflows),
    runtimeState,
    installPlan,
    workflowCatalog,
    localDeploymentPlan,
    mcpInstallPlan,
    Object.hashAll(localServers),
    notice,
  );
}

final class PluginManagementProjection {
  PluginManagementProjection({
    required Iterable<PluginProjectionItem> plugins,
    required Iterable<PresentationChoice> workflows,
    CollaborationProjection? collaboration,
    this.recommendation,
    required this.phase,
    this.notice,
  }) : plugins = immutablePresentationList(plugins),
       workflows = immutablePresentationList(workflows),
       collaboration =
           collaboration ??
           CollaborationProjection(
             statusLoaded: false,
             enabled: false,
             installed: false,
             loaded: false,
             runnerTrusted: false,
             catalogLoaded: false,
             phase: PresentationPhase.idle,
             workflows: const [],
           );

  final List<PluginProjectionItem> plugins;
  final List<PresentationChoice> workflows;
  final CollaborationProjection collaboration;

  /// The pending recommendation offer, or `null` when nothing is offered.
  final PackageRecommendationProjection? recommendation;
  final PresentationPhase phase;
  final PresentationNotice? notice;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PluginManagementProjection &&
          samePresentationList(other.plugins, plugins) &&
          samePresentationList(other.workflows, workflows) &&
          other.collaboration == collaboration &&
          other.recommendation == recommendation &&
          other.phase == phase &&
          other.notice == notice;

  @override
  int get hashCode => Object.hash(
    Object.hashAll(plugins),
    Object.hashAll(workflows),
    collaboration,
    recommendation,
    phase,
    notice,
  );
}
