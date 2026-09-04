import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/plugin_management/models/adapter_plugin_catalog.dart';
import 'package:licoup/src/composition/features/semantic_feature_channel.dart';
import 'package:licoup/src/composition/renderer_intent_trace.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_binding.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_effect.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_intent.dart';
import 'package:licoup/src/projections/plugin_management/plugin_management_projection_producer.dart';

final class PluginManagementFeatureComposition {
  PluginManagementFeatureComposition(
    ClientController controller, {
    RendererIntentTraceFactory? beginRendererIntent,
  }) : _controller = controller,
       _beginRendererIntent = beginRendererIntent {
    _projection = PluginManagementProjectionProducer(
      plugins: controller.adapterPluginController,
      collaboration: controller.optionalCollaborationController,
    );
    _effects = SemanticEffectChannel<PluginManagementEffect>();
    _intents = SemanticIntentChannel<PluginManagementIntent>(_handleIntent);
    binding = PluginManagementBinding(
      projection: _projection,
      intents: _intents,
      effects: _effects,
    );
  }

  final ClientController _controller;
  final RendererIntentTraceFactory? _beginRendererIntent;
  late final PluginManagementProjectionProducer _projection;
  late final SemanticEffectChannel<PluginManagementEffect> _effects;
  late final SemanticIntentChannel<PluginManagementIntent> _intents;
  late final PluginManagementBinding binding;
  _PendingPluginPlan? _pendingPluginPlan;
  var _nextPluginPlan = 0;
  Future<void>? _disposal;

  Future<void> _handleIntent(PluginManagementIntent intent) async {
    final trace = resolveRendererIntentTrace(
      intent.trace,
      _beginRendererIntent,
    );
    switch (intent) {
      case RefreshPlugins():
        await _controller.adapterPluginController.refresh();
      case PlanPluginInstall(:final agentId, :final pluginId):
        await _planPluginLifecycle(
          agentId: agentId,
          pluginId: pluginId,
          action: PluginLifecyclePlanAction.install,
          trace: trace,
        );
      case PlanPluginUninstall(:final agentId, :final pluginId):
        await _planPluginLifecycle(
          agentId: agentId,
          pluginId: pluginId,
          action: PluginLifecyclePlanAction.uninstall,
          trace: trace,
        );
      case ApplyPluginLifecyclePlan(:final planId):
        await _applyPluginPlan(planId, trace);
      case LoadCollaborationStatus():
        if (!await _controller.optionalCollaborationController.loadStatus()) {
          _rejectCollaboration(trace);
        }
      case SetCollaborationEnabled(:final enabled):
        final succeeded = enabled
            ? await _controller.optionalCollaborationController.enable(
                confirmed: true,
              )
            : await _controller.optionalCollaborationController.disable(
                confirmed: true,
              );
        if (!succeeded) _rejectCollaboration(trace);
      case LoadCollaborationCatalog():
        if (!await _controller.optionalCollaborationController
            .loadWorkflowCatalog()) {
          _rejectCollaboration(trace);
        }
      case PlanCollaborationInstall(
        :final githubUrl,
        :final gitRef,
        :final pluginPath,
      ):
        final owner = _controller.optionalCollaborationController;
        final succeeded = await owner.planInstall(
          githubUrl: githubUrl,
          gitRef: gitRef,
          pluginPath: pluginPath,
          confirmed: true,
        );
        final plan = owner.installPlan;
        if (!succeeded || plan == null) {
          _rejectCollaboration(trace);
        } else {
          _effects.emit(
            CollaborationInstallPlanReady(
              '${plan.sourceUrl}\n${plan.sourceRef}\n${plan.packageDigestSha256}',
              trace: trace,
            ),
          );
        }
      case ApplyCollaborationInstall():
        if (!await _controller.optionalCollaborationController.applyInstall(
          confirmed: true,
        )) {
          _rejectCollaboration(trace);
        }
      case CancelCollaborationInstall():
        if (!await _controller.optionalCollaborationController.cancelInstall(
          confirmed: true,
        )) {
          _rejectCollaboration(trace);
        }
      case ImportCollaborationRunnerTrust(
        :final keyId,
        :final publicKeyBase64url,
        :final sourceRepositoryUrl,
        :final expectedFingerprintSha256,
      ):
        if (!await _controller.optionalCollaborationController
            .importRunnerTrust(
              keyId: keyId,
              publicKeyBase64url: publicKeyBase64url,
              sourceRepositoryUrl: sourceRepositoryUrl,
              expectedFingerprintSha256: expectedFingerprintSha256,
              confirmed: true,
            )) {
          _rejectCollaboration(trace);
        }
      case RemoveCollaborationRunnerTrust():
        if (!await _controller.optionalCollaborationController
            .removeRunnerTrust(confirmed: true)) {
          _rejectCollaboration(trace);
        }
      case DisableCollaboration():
        if (!await _controller.optionalCollaborationController.disable(
          confirmed: true,
        )) {
          _rejectCollaboration(trace);
        }
      case UninstallCollaboration():
        if (!await _controller.optionalCollaborationController.uninstall(
          confirmed: true,
        )) {
          _rejectCollaboration(trace);
        }
      case PlanCollaborationLocalDeployment(
        :final selectedFeatureIds,
        :final destination,
      ):
        if (!await _controller.optionalCollaborationController.workflows
            .planLocalDeployment(
              selectedFeatureIds: selectedFeatureIds,
              destination: destination,
            )) {
          _rejectCollaboration(trace);
        }
      case ApplyCollaborationLocalDeployment():
        if (!await _controller.optionalCollaborationController.workflows
            .applyLocalDeployment(confirmed: true)) {
          _rejectCollaboration(trace);
        }
      case PlanCollaborationMcpInstall(
        :final selectedPluginIds,
        :final agentDestinations,
      ):
        if (!await _controller.optionalCollaborationController.workflows
            .planMcpInstall(
              selectedPluginIds: selectedPluginIds,
              agentDestinations: agentDestinations,
            )) {
          _rejectCollaboration(trace);
        }
      case ApplyCollaborationMcpInstall():
        if (!await _controller.optionalCollaborationController.workflows
            .applyMcpInstall(confirmed: true)) {
          _rejectCollaboration(trace);
        }
      case CancelCollaborationWorkflow(:final kind):
        if (!await _controller.optionalCollaborationController.workflows.cancel(
          kind,
          confirmed: true,
        )) {
          _rejectCollaboration(trace);
        }
      case LoadCollaborationLocalServers():
        if (!await _controller.optionalCollaborationController.workflows
            .loadLocalServerStatus()) {
          _rejectCollaboration(trace);
        }
      case StartCollaborationLocalServer(:final deploymentId):
        if (!await _controller.optionalCollaborationController.workflows
            .startLocalServer(deploymentId, confirmed: true)) {
          _rejectCollaboration(trace);
        }
      case StopCollaborationLocalServer(:final deploymentId):
        if (!await _controller.optionalCollaborationController.workflows
            .stopLocalServer(deploymentId, confirmed: true)) {
          _rejectCollaboration(trace);
        }
      case UninstallCollaborationLocalServer(:final deploymentId):
        if (!await _controller.optionalCollaborationController.workflows
            .uninstallLocalServer(deploymentId, confirmed: true)) {
          _rejectCollaboration(trace);
        }
    }
  }

  Future<void> _planPluginLifecycle({
    required String agentId,
    required String pluginId,
    required PluginLifecyclePlanAction action,
    required TraceContext? trace,
  }) async {
    _pendingPluginPlan = null;
    final adapter = _controller.adapterPluginController.catalog?.adapter(
      agentId,
    );
    final plugin = adapter == null ? null : _pluginEntry(adapter, pluginId);
    final domainAction = action == PluginLifecyclePlanAction.install
        ? AdapterPluginLifecycleAction.install
        : AdapterPluginLifecycleAction.uninstall;
    if (adapter == null || plugin == null) {
      _reject(agentId, 'adapter_plugin_missing', trace);
      return;
    }
    if (!plugin.supports(domainAction)) {
      _reject(agentId, 'adapter_plugin_action_not_declared', trace);
      return;
    }

    if (agentId == 'codex' &&
        pluginId == 'lico-up-codex' &&
        action == PluginLifecyclePlanAction.install) {
      await _planCodexPlugin(adapter, plugin, trace);
      return;
    }
    if (!adapter.supports(domainAction)) {
      _reject(agentId, 'adapter_plugin_action_not_declared', trace);
      return;
    }

    final plan = _PendingPluginPlan(
      id: _newPluginPlanId(),
      agentId: agentId,
      pluginId: pluginId,
      action: action,
    );
    _pendingPluginPlan = plan;
    _effects.emit(
      PluginLifecyclePlanReady(
        planId: plan.id,
        agentId: agentId,
        pluginId: pluginId,
        pluginLabel: plugin.label,
        action: action,
        kind: PluginInstallPlanKind.catalog,
        trace: trace,
      ),
    );
  }

  Future<void> _planCodexPlugin(
    AdapterPluginDescriptor adapter,
    AdapterPluginEntry plugin,
    TraceContext? trace,
  ) async {
    final binaryPath = _controller.scannedTargets
        .where((candidate) => candidate.target == adapter.agentId)
        .map((candidate) => candidate.binaryPath?.trim() ?? '')
        .where((value) => value.isNotEmpty)
        .firstOrNull;
    if (binaryPath == null) {
      _reject(adapter.agentId, 'codex_executable_missing', trace);
      return;
    }
    try {
      final status = await _controller.agentService.codexPluginStatus(
        binaryPath: binaryPath,
      );
      if (status['ok'] == true && status['ready'] == true) {
        await _controller.adapterPluginController.refresh();
        return;
      }
      final payload = await _controller.agentService.planCodexPlugin(
        binaryPath: binaryPath,
      );
      final digest = '${payload['digest'] ?? ''}'.trim();
      final source = '${payload['marketplaceSource'] ?? ''}'.trim();
      final release = '${payload['marketplaceRelease'] ?? ''}'.trim();
      final version = '${payload['pluginVersion'] ?? ''}'.trim();
      if (payload['ok'] != true ||
          payload['requiresConfirmation'] != true ||
          digest.isEmpty ||
          source.isEmpty ||
          release.isEmpty ||
          version.isEmpty) {
        _reject(adapter.agentId, 'codex_plugin_plan_failed', trace);
        return;
      }
      final plan = _PendingPluginPlan(
        id: _newPluginPlanId(),
        agentId: adapter.agentId,
        pluginId: plugin.id,
        action: PluginLifecyclePlanAction.install,
        binaryPath: binaryPath,
        confirmation: digest,
      );
      _pendingPluginPlan = plan;
      _effects.emit(
        PluginLifecyclePlanReady(
          planId: plan.id,
          agentId: adapter.agentId,
          pluginId: plugin.id,
          pluginLabel: plugin.label,
          action: PluginLifecyclePlanAction.install,
          kind: PluginInstallPlanKind.codexPinnedRelease,
          marketplaceSource: source,
          marketplaceRelease: release,
          pluginVersion: version,
          trace: trace,
        ),
      );
    } on Object {
      _reject(adapter.agentId, 'codex_plugin_plan_failed', trace);
    }
  }

  Future<void> _applyPluginPlan(String planId, TraceContext? trace) async {
    final plan = _pendingPluginPlan;
    if (plan == null || plan.id != planId) {
      _reject('', 'adapter_plugin_plan_expired', trace);
      return;
    }
    _pendingPluginPlan = null;
    if (plan.confirmation.isNotEmpty) {
      try {
        final result = await _controller.agentService.installCodexPlugin(
          binaryPath: plan.binaryPath,
          confirmation: plan.confirmation,
        );
        if (result['ok'] != true || result['installed'] != true) {
          _reject(plan.agentId, 'codex_plugin_install_failed', trace);
          return;
        }
        await _controller.adapterPluginController.refresh();
        _effects.emit(
          PluginActionCompleted('codex_plugin_installed', trace: trace),
        );
      } on Object {
        _reject(plan.agentId, 'codex_plugin_install_failed', trace);
      }
      return;
    }
    if (plan.action == PluginLifecyclePlanAction.install) {
      await _controller.adapterPluginController.install(plan.agentId);
    } else {
      await _controller.adapterPluginController.uninstall(plan.agentId);
    }
    final failure = _controller.adapterPluginController.lastErrorCode;
    if (failure.isNotEmpty) {
      _reject(plan.agentId, failure, trace);
      return;
    }
    _effects.emit(
      PluginActionCompleted(
        plan.action == PluginLifecyclePlanAction.install
            ? 'adapter_plugin_installed'
            : 'adapter_plugin_uninstalled',
        trace: trace,
      ),
    );
  }

  AdapterPluginEntry? _pluginEntry(
    AdapterPluginDescriptor adapter,
    String pluginId,
  ) {
    for (final plugin in adapter.plugins) {
      if (plugin.id == pluginId) return plugin;
    }
    return null;
  }

  String _newPluginPlanId() => 'plugin-plan-${++_nextPluginPlan}';

  void _rejectCollaboration(TraceContext? trace) => _reject(
    'optional-collaboration',
    _controller.optionalCollaborationController.errorCode.isEmpty
        ? 'optional_collaboration_action_failed'
        : _controller.optionalCollaborationController.errorCode,
    trace,
  );

  void _reject(String pluginId, String reason, TraceContext? trace) {
    _effects.emit(PluginActionRejected(pluginId, reason, trace: trace));
  }

  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    _pendingPluginPlan = null;
    await _projection.dispose();
    await _effects.dispose();
  }
}

final class _PendingPluginPlan {
  const _PendingPluginPlan({
    required this.id,
    required this.agentId,
    required this.pluginId,
    required this.action,
    this.binaryPath = '',
    this.confirmation = '',
  });

  final String id;
  final String agentId;
  final String pluginId;
  final PluginLifecyclePlanAction action;
  final String binaryPath;
  final String confirmation;
}
