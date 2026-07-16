import 'package:flutter_client/src/application/features/settings/controller/optional_collaboration_workflow_action_context.dart';
import 'package:flutter_client/src/application/features/settings/controller/optional_collaboration_workflow_validation.dart';
import 'package:flutter_client/src/contracts/optional_collaboration_workflow_models.dart';

final class OptionalCollaborationMcpActions {
  const OptionalCollaborationMcpActions(this.context);

  final OptionalCollaborationWorkflowActionContext context;

  Future<bool> plan({
    required List<String> selectedPluginIds,
    required List<OptionalCollaborationAgentDestination> agentDestinations,
  }) async {
    final catalog = context.catalog;
    if (catalog == null || !catalog.requiresPerFileApproval) {
      return context.rejectAction(
        'optional_collaboration_mcp_catalog_policy_required',
        '请先加载声明逐文件审批策略的工作流目录。',
        'Load a workflow catalog that declares per-file approval first.',
      );
    }
    final selected = validateOptionalCollaborationSelection(
      selectedPluginIds,
      catalog.mcpInstallChoices,
    );
    if (selected == null) {
      return context.rejectAction(
        'optional_collaboration_mcp_selection_invalid',
        '请选择目录中列出的一个或多个 MCP 插件。',
        'Select one or more MCP plugins from the catalog.',
      );
    }
    final destinations = validateOptionalCollaborationAgentDestinations(
      agentDestinations,
    );
    if (destinations == null) {
      return context.rejectAction(
        'optional_collaboration_mcp_destinations_invalid',
        '请为一个或多个支持 ACP stdio 的智能体填写互不重叠的绝对安装路径。',
        'For ACP-stdio-capable agents, provide non-overlapping absolute install paths.',
      );
    }
    if (!context.beginAction()) return false;
    try {
      final plan = await context.gateway.planMcpInstall(
        selectedPluginIds: selected,
        agentDestinations: destinations,
      );
      if (!plan.matchesMcpRequest(selected, destinations) ||
          plan.pluginId != catalog.plugin.id ||
          plan.packageDigestSha256 != catalog.plugin.packageDigestSha256) {
        throw const FormatException(
          'optional_collaboration_mcp_plan_binding_invalid',
        );
      }
      context.mcpInstallPlan = plan;
      context.lastApplyResult = null;
      context.reportAction(
        'MCP 本机安装计划已生成，请核对每个智能体、路径、摘要和文件。',
        'Local MCP installation plan created. Review every agent, path, digest, and file.',
      );
      return true;
    } catch (_) {
      context.mcpInstallPlan = null;
      context.failAction(
        'optional_collaboration_mcp_plan_failed',
        'MCP 本机安装计划生成失败。',
        'Failed to create the local MCP installation plan.',
      );
      return false;
    } finally {
      context.endAction();
    }
  }

  Future<bool> apply({required bool confirmed}) async {
    final plan = context.mcpInstallPlan;
    if (plan == null) {
      return context.rejectAction(
        'optional_collaboration_mcp_plan_required',
        '请先生成 MCP 本机安装计划。',
        'Create a local MCP installation plan first.',
      );
    }
    if (!confirmed) return _confirmationRequired();
    if (!context.beginAction()) return false;
    try {
      context.lastApplyResult = await context.gateway.applyMcpInstall(
        plan: plan,
        confirmed: true,
      );
      context.mcpInstallPlan = null;
      context.reportAction(
        'MCP 文件和 LicoArc 私有智能体注册已按精确计划一次完成；认证审批代理尚未实现，因此外发桥接保持关闭。',
        'MCP files and private LicoArc registrations were applied in one exact transaction. Outbound bridge activation remains disabled because the authenticated review broker is not implemented.',
      );
      return true;
    } catch (_) {
      context.failAction(
        'optional_collaboration_mcp_apply_failed',
        'MCP 本机安装计划应用失败。',
        'Failed to apply the local MCP installation plan.',
      );
      return false;
    } finally {
      context.endAction();
    }
  }

  Future<bool> cancel({required bool confirmed}) async {
    final plan = context.mcpInstallPlan;
    if (plan == null) {
      return context.rejectAction(
        'optional_collaboration_workflow_plan_required',
        '没有可取消的 MCP 安装计划。',
        'There is no MCP installation plan to cancel.',
      );
    }
    if (!confirmed) return _confirmationRequired();
    if (!context.beginAction()) return false;
    try {
      await context.gateway.cancelWorkflow(plan: plan, confirmed: true);
      context.mcpInstallPlan = null;
      context.reportAction(
        'MCP 安装计划已取消并作废。',
        'The MCP installation plan was cancelled and consumed.',
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

  bool _confirmationRequired() => context.rejectAction(
    'optional_collaboration_workflow_confirmation_required',
    '应用或取消前必须直接确认当前精确计划。',
    'Directly confirm the current exact plan before applying or cancelling it.',
  );
}
