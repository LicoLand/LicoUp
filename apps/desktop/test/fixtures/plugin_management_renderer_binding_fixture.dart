import 'dart:async';

import 'package:licoup/src/application/features/plugin_management/controller/adapter_plugin_controller.dart';
import 'package:licoup/src/application/features/settings/controller/optional_collaboration_controller.dart';
import 'package:licoup/src/composition/features/semantic_feature_channel.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_binding.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_effect.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_intent.dart';
import 'package:licoup/src/projections/plugin_management/plugin_management_projection_producer.dart';

/// Test-only semantic assembly for the standalone collaboration renderer.
final class PluginManagementRendererBindingFixture {
  PluginManagementRendererBindingFixture(this._collaboration)
    : _plugins = AdapterPluginController(
        runner: const _EmptyPluginRunner(),
        onStatus: (_) {},
      ) {
    _projection = PluginManagementProjectionProducer(
      plugins: _plugins,
      collaboration: _collaboration,
    );
    _effects = SemanticEffectChannel<PluginManagementEffect>();
    _intents = SemanticIntentChannel<PluginManagementIntent>(_handleIntent);
    binding = PluginManagementBinding(
      projection: _projection,
      intents: _intents,
      effects: _effects,
    );
  }

  final OptionalCollaborationController _collaboration;
  final AdapterPluginController _plugins;
  late final PluginManagementProjectionProducer _projection;
  late final SemanticEffectChannel<PluginManagementEffect> _effects;
  late final SemanticIntentChannel<PluginManagementIntent> _intents;
  late final PluginManagementBinding binding;
  Future<void>? _disposal;

  Future<void> _handleIntent(PluginManagementIntent intent) async {
    switch (intent) {
      case RefreshPlugins():
        await _plugins.refresh();
      case PlanPluginInstall() ||
          PlanPluginUninstall() ||
          ApplyPluginLifecyclePlan():
        break;
      case LoadCollaborationStatus():
        await _collaboration.loadStatus();
      case SetCollaborationEnabled(:final enabled):
        if (enabled) {
          await _collaboration.enable(confirmed: true);
        } else {
          await _collaboration.disable(confirmed: true);
        }
      case LoadCollaborationCatalog():
        await _collaboration.loadWorkflowCatalog();
      case PlanCollaborationInstall(
        :final githubUrl,
        :final gitRef,
        :final pluginPath,
      ):
        final succeeded = await _collaboration.planInstall(
          githubUrl: githubUrl,
          gitRef: gitRef,
          pluginPath: pluginPath,
          confirmed: true,
        );
        final plan = _collaboration.installPlan;
        if (succeeded && plan != null) {
          _effects.emit(
            CollaborationInstallPlanReady(
              '${plan.sourceUrl}\n${plan.sourceRef}\n'
              '${plan.packageDigestSha256}',
              trace: intent.trace,
            ),
          );
        }
      case ApplyCollaborationInstall():
        await _collaboration.applyInstall(confirmed: true);
      case CancelCollaborationInstall():
        await _collaboration.cancelInstall(confirmed: true);
      case ImportCollaborationRunnerTrust(
        :final keyId,
        :final publicKeyBase64url,
        :final sourceRepositoryUrl,
        :final expectedFingerprintSha256,
      ):
        await _collaboration.importRunnerTrust(
          keyId: keyId,
          publicKeyBase64url: publicKeyBase64url,
          sourceRepositoryUrl: sourceRepositoryUrl,
          expectedFingerprintSha256: expectedFingerprintSha256,
          confirmed: true,
        );
      case RemoveCollaborationRunnerTrust():
        await _collaboration.removeRunnerTrust(confirmed: true);
      case DisableCollaboration():
        await _collaboration.disable(confirmed: true);
      case UninstallCollaboration():
        await _collaboration.uninstall(confirmed: true);
      case PlanCollaborationLocalDeployment(
        :final selectedFeatureIds,
        :final destination,
      ):
        await _collaboration.workflows.planLocalDeployment(
          selectedFeatureIds: selectedFeatureIds,
          destination: destination,
        );
      case ApplyCollaborationLocalDeployment():
        await _collaboration.workflows.applyLocalDeployment(confirmed: true);
      case PlanCollaborationMcpInstall(
        :final selectedPluginIds,
        :final agentDestinations,
      ):
        await _collaboration.workflows.planMcpInstall(
          selectedPluginIds: selectedPluginIds,
          agentDestinations: agentDestinations,
        );
      case ApplyCollaborationMcpInstall():
        await _collaboration.workflows.applyMcpInstall(confirmed: true);
      case CancelCollaborationWorkflow(:final kind):
        await _collaboration.workflows.cancel(kind, confirmed: true);
      case LoadCollaborationLocalServers():
        await _collaboration.workflows.loadLocalServerStatus();
      case StartCollaborationLocalServer(:final deploymentId):
        await _collaboration.workflows.startLocalServer(
          deploymentId,
          confirmed: true,
        );
      case StopCollaborationLocalServer(:final deploymentId):
        await _collaboration.workflows.stopLocalServer(
          deploymentId,
          confirmed: true,
        );
      case UninstallCollaborationLocalServer(:final deploymentId):
        await _collaboration.workflows.uninstallLocalServer(
          deploymentId,
          confirmed: true,
        );
    }
  }

  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    await _projection.dispose();
    await _effects.dispose();
    _plugins.dispose();
  }
}

final class _EmptyPluginRunner implements AgentCommandRunner {
  const _EmptyPluginRunner();

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) async => const {
    'ok': true,
    'schemaVersion': 'lico.adapter-plugin-catalog.v1',
    'adapters': <Object>[],
  };

  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) async => runCli(args);

  @override
  Stream<Map<String, dynamic>> streamCliJsonLines(List<String> args) =>
      const Stream.empty();

  @override
  Stream<Map<String, dynamic>> streamCliJsonLinesWithStdin(
    List<String> args,
    String stdinText,
  ) => const Stream.empty();
}
