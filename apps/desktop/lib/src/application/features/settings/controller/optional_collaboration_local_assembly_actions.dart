import 'package:flutter_client/src/application/features/settings/controller/optional_collaboration_workflow_action_context.dart';
import 'package:flutter_client/src/application/features/settings/controller/optional_collaboration_workflow_validation.dart';

final class OptionalCollaborationLocalAssemblyActions {
  const OptionalCollaborationLocalAssemblyActions(this.context);

  final OptionalCollaborationWorkflowActionContext context;

  Future<bool> plan({
    required List<String> selectedFeatureIds,
    required String destination,
  }) async {
    final catalog = context.catalog;
    if (catalog == null) {
      return context.rejectAction(
        'optional_collaboration_workflow_catalog_required',
        '请先显式加载工作流目录。',
        'Explicitly load the workflow catalog first.',
      );
    }
    final selected = validateOptionalCollaborationSelection(
      selectedFeatureIds,
      catalog.localDeploymentChoices,
    );
    if (selected == null) {
      return context.rejectAction(
        'optional_collaboration_local_selection_invalid',
        '请选择目录中列出的一个或多个本机组装组件。',
        'Select one or more local assembly components from the catalog.',
      );
    }
    final target = destination.trim();
    if (!looksLikeOptionalCollaborationAbsolutePath(target)) {
      return context.rejectAction(
        'optional_collaboration_local_destination_invalid',
        '请选择新的绝对目标路径。',
        'Choose a new absolute destination path.',
      );
    }
    if (!context.beginAction()) return false;
    try {
      final plan = await context.gateway.planLocalDeployment(
        selectedFeatureIds: selected,
        destination: target,
      );
      if (!plan.matchesLocalRequest(selected, target) ||
          plan.pluginId != catalog.plugin.id ||
          plan.packageDigestSha256 != catalog.plugin.packageDigestSha256 ||
          plan.localAssembly?.sourceCommitOid !=
              catalog.plugin.sourceCommitOid ||
          plan.localAssembly?.signedPackageInventoryDigestSha256 !=
              catalog.plugin.signedPackageInventoryDigestSha256 ||
          plan.localAssembly?.runnerTrustKeyId !=
              catalog.plugin.runnerTrustKeyId ||
          plan.localAssembly?.runnerTrustFingerprintSha256 !=
              catalog.plugin.runnerTrustFingerprintSha256) {
        throw const FormatException(
          'optional_collaboration_local_plan_binding_invalid',
        );
      }
      context.localDeploymentPlan = plan;
      context.lastApplyResult = null;
      context.reportAction(
        '本机组装计划已生成，请核对精确选择、目标路径、runner 绑定、双摘要和逐文件清单。',
        'Local assembly plan created. Review the selection, destination, runner binding, both digests, and file list.',
      );
      return true;
    } catch (_) {
      context.localDeploymentPlan = null;
      context.failAction(
        'optional_collaboration_local_plan_failed',
        '本机组装计划生成失败。',
        'Failed to create the local assembly plan.',
      );
      return false;
    } finally {
      context.endAction();
    }
  }

  Future<bool> apply({required bool confirmed}) async {
    final plan = context.localDeploymentPlan;
    if (plan == null) {
      return context.rejectAction(
        'optional_collaboration_local_plan_required',
        '请先生成本机组装计划。',
        'Create a local assembly plan first.',
      );
    }
    if (!confirmed) return _confirmationRequired();
    if (!context.beginAction()) return false;
    try {
      final result = await context.gateway.applyLocalDeployment(
        plan: plan,
        confirmed: true,
      );
      context.lastApplyResult = result;
      final server = result.localServer;
      if (server == null || !server.isAwaitingDeployment) {
        throw const FormatException(
          'optional_collaboration_local_server_apply_result_required',
        );
      }
      context.replaceLocalServer(server);
      context.localDeploymentPlan = null;
      context.reportAction(
        'LicoMesh 组件已完成本机组装，当前等待单独部署确认；受签名 runner 尚未执行。',
        'The LicoMesh components are assembled and awaiting separate deployment approval; the signed runner has not executed.',
      );
      return true;
    } catch (_) {
      context.failAction(
        'optional_collaboration_local_apply_failed',
        '本机组装计划应用失败。',
        'Failed to apply the local assembly plan.',
      );
      return false;
    } finally {
      context.endAction();
    }
  }

  Future<bool> cancel({required bool confirmed}) async {
    final plan = context.localDeploymentPlan;
    if (plan == null) return _planRequired();
    if (!confirmed) return _confirmationRequired();
    if (!context.beginAction()) return false;
    try {
      await context.gateway.cancelWorkflow(plan: plan, confirmed: true);
      context.localDeploymentPlan = null;
      context.reportAction(
        '本机组装计划已取消并作废。',
        'The local assembly plan was cancelled and consumed.',
      );
      return true;
    } catch (_) {
      context.failAction(
        'optional_collaboration_workflow_cancel_failed',
        '工作流计划取消失败。',
        'Failed to cancel the workflow plan.',
      );
      return false;
    } finally {
      context.endAction();
    }
  }

  bool _planRequired() => context.rejectAction(
    'optional_collaboration_workflow_plan_required',
    '没有可取消的本机组装计划。',
    'There is no local assembly plan to cancel.',
  );

  bool _confirmationRequired() => context.rejectAction(
    'optional_collaboration_workflow_confirmation_required',
    '应用或取消前必须直接确认当前精确计划。',
    'Directly confirm the current exact plan before applying or cancelling it.',
  );
}
