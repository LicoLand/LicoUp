import 'package:flutter/material.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/agents/orchestration/orchestration_policy_editor_models.dart';
import 'package:licoup/src/application/features/messaging/messaging_notification_center.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_orchestration_policy_dialog.dart';
import 'package:licoup/src/frontend/features/agents/ui/ensure_main_agent_subagent_mcp.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/agent_brand_icon.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

export 'package:licoup/src/frontend/features/agents/ui/agent_orchestration_policy_dialog.dart';

final class AgentOrchestrationPolicyHeaderControls extends StatelessWidget {
  const AgentOrchestrationPolicyHeaderControls({
    super.key,
    required this.mainAgentLabel,
    required this.mainAgentTarget,
    required this.onEdit,
  });

  final String mainAgentLabel;
  final TargetCandidate? mainAgentTarget;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    // The whole pill is the edit affordance: one tap target, one tooltip.
    return Tooltip(
      message: strings.editMainAgent,
      waitDuration: LicoMotion.tooltipWait,
      child: Semantics(
        button: true,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            key: const Key('main-agent-edit'),
            behavior: HitTestBehavior.opaque,
            onTap: onEdit,
            child: Container(
              height: 30,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                color: colors.isDark
                    ? Colors.white.withAlpha(18)
                    : Colors.white.withAlpha(160),
                border: Border.all(
                  color: colors.line.withAlpha(colors.isDark ? 100 : 130),
                  width: 0.5,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (mainAgentTarget case final mainAgentTarget?)
                    AgentBrandIcon(
                      target: mainAgentTarget,
                      size: 15,
                      iconSize: 15,
                    )
                  else
                    Icon(
                      Icons.smart_toy_outlined,
                      size: 15,
                      color: colors.textMuted.withAlpha(230),
                    ),
                  const SizedBox(width: 6),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 240),
                    child: Text(
                      mainAgentLabel,
                      key: const Key('main-agent-label'),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> showAgentOrchestrationPolicyEditor(
  BuildContext context,
  ClientController controller,
) async {
  final policy = await showDialog<AgentOrchestrationPolicy>(
    context: context,
    builder: (_) => AgentOrchestrationPolicyDialog(controller: controller),
  );
  if (policy == null || !context.mounted) return;
  var pluginReady = false;
  final commanderId = policy.commanderAgentId.trim();
  if (commanderId == 'codex' || commanderId == 'antigravity') {
    pluginReady = await ensureMainAgentSubagentMcp(
      context: context,
      controller: controller,
      agentId: commanderId,
    );
    if (!context.mounted) return;
  }
  await controller.saveAgentOrchestrationPolicy(policy);
  if (!context.mounted) return;
  if (commanderId != 'codex' && commanderId != 'antigravity') return;
  controller.agentWorkspacePublishNotification(
    id: 'subagent-mcp-$commanderId',
    messageChinese: pluginReady
        ? 'Subagent MCP 已就绪，$commanderId 可通过 LicoUp handoff 调度同伴。'
        : 'Subagent MCP 未就绪；群聊发送前仍需完成安装确认。',
    messageEnglish: pluginReady
        ? 'Subagent MCP is ready; $commanderId can hand off peers through LicoUp.'
        : 'Subagent MCP is not ready; finish install confirmation before group send.',
    tone: pluginReady
        ? MessagingNotificationTone.success
        : MessagingNotificationTone.warning,
    code: pluginReady ? 'subagent_mcp_ready' : 'subagent_mcp_required',
  );
}
