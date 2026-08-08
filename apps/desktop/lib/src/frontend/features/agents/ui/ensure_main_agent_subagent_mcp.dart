import 'package:flutter/material.dart';
import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/messaging/messaging_notification_center.dart';
import 'package:licoup/src/contracts/target_candidate.dart';

/// Ensure the Current Conversation main agent has Subagent MCP ready.
/// Never silent: missing supported agents require digest confirmation.
/// Returns true when ready, false when declined/failed/unsupported.
Future<bool> ensureMainAgentSubagentMcp({
  required BuildContext context,
  required ClientController controller,
  required String agentId,
}) async {
  final id = agentId.trim();
  if (id.isEmpty) return false;

  TargetCandidate? target;
  for (final candidate in controller.orchestrationAvailableTargets) {
    if (candidate.target == id) {
      target = candidate;
      break;
    }
  }
  final binaryPath = target?.binaryPath?.trim() ?? '';

  try {
    final status = await controller.agentService.subagentMcpStatus(
      agentId: id,
      binaryPath: binaryPath.isEmpty ? null : binaryPath,
    );
    final state = status['state']?.toString() ?? '';
    if (status['ok'] == true && status['ready'] == true) {
      controller.messagingNotificationCenter.dismiss('subagent-mcp-$id');
      return true;
    }
    if (state == 'unsupported') {
      // Subagent MCP enables handoffs; it must not hard-block inbound user turns
      // for agents that never support the plugin (for example Cursor).
      controller.agentWorkspacePublishNotification(
        id: 'subagent-mcp-$id',
        messageChinese: '主智能体（$id）不支持 Subagent MCP，无法通过 handoff 调度同伴；普通发送仍会继续。',
        messageEnglish:
            'Main agent ($id) does not support Subagent MCP, so peer handoffs are unavailable; plain send continues.',
        tone: MessagingNotificationTone.warning,
        code: 'subagent_mcp_unsupported',
      );
      return true;
    }
  } catch (_) {
    // Fall through to plan/install when status probe fails.
  }

  Map<String, dynamic> plan;
  try {
    plan = await controller.agentService.planSubagentMcp(
      agentId: id,
      binaryPath: binaryPath.isEmpty ? null : binaryPath,
    );
  } catch (_) {
    controller.agentWorkspacePublishNotification(
      id: 'subagent-mcp-$id',
      messageChinese: '无法为 $id 准备 Subagent MCP 安装计划。',
      messageEnglish: 'Could not prepare a Subagent MCP install plan for $id.',
      tone: MessagingNotificationTone.warning,
      code: 'subagent_mcp_plan_failed',
    );
    return false;
  }
  if (plan['ok'] != true || plan['requiresConfirmation'] != true) {
    controller.agentWorkspacePublishNotification(
      id: 'subagent-mcp-$id',
      messageChinese: '请先为 $id 安装并确认 Subagent MCP。',
      messageEnglish: 'Install and confirm Subagent MCP for $id first.',
      tone: MessagingNotificationTone.warning,
      code: 'subagent_mcp_required',
    );
    return false;
  }
  final digest = plan['digest']?.toString() ?? '';
  final source = plan['marketplaceSource']?.toString() ?? '';
  final release = plan['marketplaceRelease']?.toString() ?? '';
  final version = plan['pluginVersion']?.toString() ?? '';
  if (digest.isEmpty ||
      source.isEmpty ||
      release.isEmpty ||
      version.isEmpty ||
      !context.mounted) {
    return false;
  }

  final confirmed =
      await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('Install Subagent MCP for $id'),
          content: Text(
            'LicoUp will register Subagent MCP from $source ($release / $version) '
            'so $id can request LicoUp-owned handoffs. Installation is never silent.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Install'),
            ),
          ],
        ),
      ) ??
      false;
  if (!confirmed) return false;

  try {
    final result = await controller.agentService.installSubagentMcp(
      agentId: id,
      confirmation: digest,
      binaryPath: binaryPath.isEmpty ? null : binaryPath,
    );
    return result['ok'] == true &&
        result['installed'] == true &&
        result['pluginReadyForNewConversations'] == true;
  } catch (_) {
    return false;
  }
}
