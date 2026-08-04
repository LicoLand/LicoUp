import 'package:flutter/material.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/agents/orchestration/orchestration_policy_editor_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_orchestration_policy_dialog.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/agent_brand_icon.dart';
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
      waitDuration: const Duration(milliseconds: 400),
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
  if (policy.commanderAgentId == 'codex') {
    pluginReady = await _offerCodexPlugin(context, controller, policy);
    if (!context.mounted) return;
  }
  await controller.saveAgentOrchestrationPolicy(policy);
  if (!context.mounted || policy.commanderAgentId != 'codex') return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        pluginReady
            ? 'LicoUp Codex Plugin 已就绪，新对话将由 Codex 主线程调度。'
            : 'Codex 插件未就绪，将使用 LicoUp 顺序调度作为回退。',
      ),
    ),
  );
}

Future<bool> _offerCodexPlugin(
  BuildContext context,
  ClientController controller,
  AgentOrchestrationPolicy policy,
) async {
  TargetCandidate? target;
  for (final candidate in controller.orchestrationAvailableTargets) {
    if (candidate.target == policy.commanderAgentId) {
      target = candidate;
      break;
    }
  }
  final binaryPath = target?.binaryPath?.trim() ?? '';
  if (binaryPath.isEmpty) return false;

  try {
    final status = await controller.agentService.codexPluginStatus(
      binaryPath: binaryPath,
    );
    if (status['ok'] == true && status['ready'] == true) return true;
  } catch (_) {
    // A failed optional probe selects the LicoUp fallback unless installation
    // is explicitly approved below.
  }

  Map<String, dynamic> plan;
  try {
    plan = await controller.agentService.planCodexPlugin(
      binaryPath: binaryPath,
    );
  } catch (_) {
    return false;
  }
  if (plan['ok'] != true || plan['requiresConfirmation'] != true) {
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
          title: const Text('启用 LicoUp Codex Plugin'),
          content: Text(
            'Codex 将从 GitHub $source 的 $release 安装 $version。'
            'LicoUp 只提供本机运行时；安装后，新建 Codex 对话可直接调度其它智能体。'
            '跳过安装时，LicoUp 会继续提供顺序调度回退。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('使用 LicoUp 回退'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('安装插件'),
            ),
          ],
        ),
      ) ??
      false;
  if (!confirmed) return false;

  try {
    final result = await controller.agentService.installCodexPlugin(
      binaryPath: binaryPath,
      confirmation: digest,
    );
    return result['ok'] == true &&
        result['installed'] == true &&
        result['pluginReadyForNewConversations'] == true;
  } catch (_) {
    return false;
  }
}
