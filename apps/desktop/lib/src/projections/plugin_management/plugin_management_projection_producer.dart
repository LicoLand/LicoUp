import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/features/plugin_management/controller/adapter_plugin_controller.dart';
import 'package:licoup/src/application/features/plugin_management/models/adapter_plugin_catalog.dart';
import 'package:licoup/src/application/features/settings/controller/optional_collaboration_controller.dart';
import 'package:licoup/src/application/state/application_signal.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_projection.dart';
import 'package:licoup/src/projections/close_broadcast_controller.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

final class PluginManagementProjectionProducer
    implements ProjectionSource<PluginManagementProjection> {
  PluginManagementProjectionProducer({
    required AdapterPluginController plugins,
    required OptionalCollaborationController collaboration,
  }) : _plugins = plugins,
       _collaboration = collaboration,
       _current = _read(plugins, collaboration) {
    _subscriptions = [
      plugins.changes.listen(_handleChange),
      collaboration.changes.listen(_handleChange),
    ];
  }

  final AdapterPluginController _plugins;
  final OptionalCollaborationController _collaboration;
  final StreamController<ProjectionUpdate<PluginManagementProjection>>
  _changes =
      StreamController<ProjectionUpdate<PluginManagementProjection>>.broadcast(
        sync: true,
      );
  late final List<StreamSubscription<ApplicationChange>> _subscriptions;
  PluginManagementProjection _current;
  bool _disposed = false;

  @override
  PluginManagementProjection get current => _current;

  @override
  Stream<ProjectionUpdate<PluginManagementProjection>> get changes =>
      _changes.stream;

  void _handleChange(ApplicationChange change) {
    if (_disposed) return;
    final next = _read(_plugins, _collaboration);
    if (next == _current) return;
    _current = next;
    _changes.add(ProjectionUpdate(next, trace: _trace(change.cause)));
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final subscription in _subscriptions.reversed) {
      await subscription.cancel();
    }
    await closeBroadcastController(_changes);
  }

  static PluginManagementProjection _read(
    AdapterPluginController plugins,
    OptionalCollaborationController collaboration,
  ) {
    final failure = plugins.lastErrorCode.isNotEmpty
        ? plugins.lastErrorCode
        : collaboration.errorCode;
    final state = collaboration.state;
    final catalog = collaboration.workflowCatalog;
    final workflows = [
      ...?catalog?.localDeploymentChoices,
      ...?catalog?.mcpInstallChoices,
    ];
    return PluginManagementProjection(
      plugins: [for (final adapter in plugins.adapters) _adapter(adapter)],
      workflows: [
        for (final workflow in workflows)
          PresentationChoice(
            id: workflow.id,
            label: workflow.label,
            description: workflow.description,
          ),
      ],
      collaboration: CollaborationProjection(
        statusLoaded: collaboration.statusLoaded,
        enabled: state?.capabilityEnabled == true,
        installed: state?.pluginInstalled == true,
        loaded: state?.pluginLoaded == true,
        runnerTrusted: state?.runnerTrust != null,
        catalogLoaded: collaboration.catalogLoaded,
        phase: collaboration.errorCode.isNotEmpty
            ? PresentationPhase.failed
            : collaboration.busy
            ? PresentationPhase.applying
            : PresentationPhase.ready,
        workflows: [
          for (final workflow in workflows)
            PresentationChoice(
              id: workflow.id,
              label: workflow.label,
              description: workflow.description,
            ),
        ],
        runtimeState: state,
        installPlan: collaboration.installPlan,
        workflowCatalog: catalog,
        localDeploymentPlan: collaboration.workflows.localDeploymentPlan,
        mcpInstallPlan: collaboration.workflows.mcpInstallPlan,
        localServers: collaboration.workflows.localServers,
        notice: collaboration.errorCode.isEmpty
            ? null
            : _notice('collaboration-failure', collaboration.errorCode),
      ),
      phase: failure.isNotEmpty
          ? PresentationPhase.failed
          : plugins.busy || collaboration.busy
          ? PresentationPhase.loading
          : PresentationPhase.ready,
      notice: failure.isEmpty
          ? null
          : _notice('plugin-management-failure', failure),
    );
  }

  static PluginProjectionItem _adapter(AdapterPluginDescriptor adapter) {
    final installable =
        adapter.supports(AdapterPluginLifecycleAction.install) ||
        adapter.plugins.any(
          (plugin) => plugin.supports(AdapterPluginLifecycleAction.install),
        );
    final uninstallable =
        adapter.supports(AdapterPluginLifecycleAction.uninstall) ||
        adapter.plugins.any(
          (plugin) => plugin.supports(AdapterPluginLifecycleAction.uninstall),
        );
    final installed =
        adapter.installationState == 'installed' ||
        adapter.plugins.any(
          (plugin) => plugin.installationState == 'installed',
        );
    return PluginProjectionItem(
      id: adapter.agentId,
      name: _agentLabel(adapter.label),
      description: adapter.plugins.isEmpty
          ? adapter.laneFamily
          : adapter.plugins
                .map((plugin) => plugin.detail)
                .where((value) => value.isNotEmpty)
                .join('\n'),
      enabled: installed,
      installed: installed,
      installable: installable,
      uninstallable: uninstallable,
      runtimeStateLabel: adapter.readiness,
      protocolLabel: adapter.runtimeProtocol,
      capabilities: [
        for (final capability in adapter.nativeCapabilities)
          PluginCapabilityProjection(
            id: capability.kind.wireName,
            label: capability.kind.wireName,
            detected: capability.detected,
            running: capability.running,
            pid: capability.pid,
            processName: capability.processName,
            port: capability.port,
          ),
      ],
      plugins: [
        for (final plugin in adapter.plugins)
          PluginEntryProjection(
            id: plugin.id,
            label: plugin.label,
            detail: plugin.detail,
            installationState: plugin.installationState,
            installable: plugin.supports(AdapterPluginLifecycleAction.install),
            uninstallable: plugin.supports(
              AdapterPluginLifecycleAction.uninstall,
            ),
          ),
      ],
    );
  }

  static String _agentLabel(String value) {
    final suffix = value.indexOf(' - ');
    return suffix < 0 ? value : value.substring(0, suffix);
  }

  static PresentationNotice _notice(String id, String reason) =>
      PresentationNotice(
        id: id,
        title: 'Plugin Management',
        message: reason,
        severity: PresentationNoticeSeverity.error,
        reasonCode: reason,
      );
}

TraceContext? _trace(ApplicationCause? cause) =>
    cause?.traceId == null ? null : TraceContext(traceId: cause!.traceId);
