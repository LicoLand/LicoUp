import 'package:flutter_client/src/application/features/settings/controller/optional_collaboration_workflow_action_context.dart';

final class OptionalCollaborationServerRuntimeActions {
  const OptionalCollaborationServerRuntimeActions(this.context);

  final OptionalCollaborationWorkflowActionContext context;

  Future<bool> loadStatus() async {
    if (!context.beginAction()) return false;
    try {
      context.localServers = await context.gateway.loadLocalServerStatus();
      context.reportAction(
        '本机组装与部署状态已刷新。',
        'Local assembly and deployment state refreshed.',
      );
      return true;
    } catch (_) {
      context.failAction(
        'optional_collaboration_local_server_status_failed',
        '本机组装与部署状态刷新失败。',
        'Failed to refresh local assembly and deployment state.',
      );
      return false;
    } finally {
      context.endAction();
    }
  }

  Future<bool> start(String deploymentId, {required bool confirmed}) async {
    final server = context.localServerById(deploymentId);
    if (server == null || !server.isAwaitingDeployment) {
      return context.rejectAction(
        'optional_collaboration_local_server_start_state_invalid',
        '只能部署已完成组装且正在等待部署的服务端。',
        'Only an assembled server awaiting deployment can be deployed.',
      );
    }
    if (!confirmed) return _confirmationRequired();
    if (!context.beginAction()) return false;
    try {
      final started = await context.gateway.startLocalServer(
        deploymentId: deploymentId,
        confirmed: true,
      );
      if (started.deploymentId != deploymentId ||
          !started.isRunning ||
          !started.healthVerified ||
          !started.capabilitiesVerified ||
          !started.sameAssemblyAs(server)) {
        throw const FormatException(
          'optional_collaboration_local_server_start_binding_invalid',
        );
      }
      context.replaceLocalServer(started);
      context.reportAction(
        '受签名的固定 LicoLite runner 已部署并启动；健康与能力契约均已验证。',
        'The signed fixed LicoLite runner is deployed and running; health and capability contracts are verified.',
      );
      return true;
    } catch (_) {
      context.failAction(
        'optional_collaboration_local_server_start_failed',
        '受签名 LicoLite runner 部署启动失败。',
        'Failed to deploy and start the signed LicoLite runner.',
      );
      return false;
    } finally {
      context.endAction();
    }
  }

  Future<bool> stop(String deploymentId, {required bool confirmed}) async {
    final server = context.localServerById(deploymentId);
    if (server == null || !server.isRunning) {
      return context.rejectAction(
        'optional_collaboration_local_server_stop_state_invalid',
        '只能停止当前正在运行的本机部署。',
        'Only a running local deployment can be stopped.',
      );
    }
    if (!confirmed) return _confirmationRequired();
    if (!context.beginAction()) return false;
    try {
      final stopped = await context.gateway.stopLocalServer(
        deploymentId: deploymentId,
        confirmed: true,
      );
      if (stopped.deploymentId != deploymentId ||
          !stopped.isAwaitingDeployment ||
          !stopped.sameAssemblyAs(server)) {
        throw const FormatException(
          'optional_collaboration_local_server_stop_binding_invalid',
        );
      }
      context.replaceLocalServer(stopped);
      context.reportAction(
        '本机 LicoLite 部署已停止，组装产物保留为待部署状态。',
        'The local LicoLite deployment stopped; assembled output remains awaiting deployment.',
      );
      return true;
    } catch (_) {
      context.failAction(
        'optional_collaboration_local_server_stop_failed',
        '本机 LicoLite 部署停止失败。',
        'Failed to stop the local LicoLite deployment.',
      );
      return false;
    } finally {
      context.endAction();
    }
  }

  Future<bool> uninstall(String deploymentId, {required bool confirmed}) async {
    final server = context.localServerById(deploymentId);
    if (server == null || !server.isAwaitingDeployment) {
      return context.rejectAction(
        'optional_collaboration_local_server_uninstall_state_invalid',
        '卸载前必须先停止本机部署。',
        'Stop the local deployment before uninstalling its assembly.',
      );
    }
    if (!confirmed) return _confirmationRequired();
    if (!context.beginAction()) return false;
    try {
      final result = await context.gateway.uninstallLocalServer(
        deploymentId: deploymentId,
        expectedAssemblyManifestDigestSha256:
            server.assemblyManifestDigestSha256,
        confirmed: true,
      );
      if (result.deploymentId != deploymentId ||
          result.assemblyManifestDigestSha256 !=
              server.assemblyManifestDigestSha256) {
        throw const FormatException(
          'optional_collaboration_local_server_uninstall_binding_invalid',
        );
      }
      context.localServers = List.unmodifiable(
        context.localServers.where((item) => item.deploymentId != deploymentId),
      );
      context.reportAction(
        result.cleanupPending ? '本机组装已卸载，清理仍待完成。' : '本机组装已卸载。',
        result.cleanupPending
            ? 'Local assembly uninstalled; cleanup is still pending.'
            : 'Local assembly uninstalled.',
      );
      return true;
    } catch (_) {
      context.failAction(
        'optional_collaboration_local_server_uninstall_failed',
        '本机组装卸载失败。',
        'Failed to uninstall the local assembly.',
      );
      return false;
    } finally {
      context.endAction();
    }
  }

  bool _confirmationRequired() => context.rejectAction(
    'optional_collaboration_local_server_confirmation_required',
    '部署启动、停止或卸载前必须单独直接确认。',
    'Separate direct confirmation is required before deploy/start, stop, or uninstall.',
  );
}
