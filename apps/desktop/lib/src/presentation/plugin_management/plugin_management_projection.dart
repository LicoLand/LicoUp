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
    Object.hashAll(capabilities),
    Object.hashAll(plugins),
  );
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
  final PresentationPhase phase;
  final PresentationNotice? notice;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PluginManagementProjection &&
          samePresentationList(other.plugins, plugins) &&
          samePresentationList(other.workflows, workflows) &&
          other.collaboration == collaboration &&
          other.phase == phase &&
          other.notice == notice;

  @override
  int get hashCode => Object.hash(
    Object.hashAll(plugins),
    Object.hashAll(workflows),
    collaboration,
    phase,
    notice,
  );
}
