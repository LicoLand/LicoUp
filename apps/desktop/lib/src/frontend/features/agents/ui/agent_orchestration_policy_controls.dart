import 'package:flutter/material.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/agents/orchestration/orchestration_policy_editor_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_pane_controls.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_orchestration_policy_dialog.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/apple_popup_select.dart';

export 'package:licoup/src/frontend/features/agents/ui/agent_orchestration_policy_dialog.dart';

final class AgentOrchestrationPolicyHeaderControls extends StatelessWidget {
  const AgentOrchestrationPolicyHeaderControls({
    super.key,
    required this.policy,
    required this.policies,
    required this.policyLabel,
    required this.onSelectPolicy,
    required this.onEditPolicy,
  });

  final AgentOrchestrationPolicy policy;
  final List<AgentOrchestrationPolicy> policies;
  final String Function(AgentOrchestrationPolicy) policyLabel;
  final ValueChanged<String> onSelectPolicy;
  final VoidCallback onEditPolicy;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 240, minWidth: 176),
          child: ApplePopupSelect<String>(
            key: const Key('agent-orchestration-policy-select'),
            value: policy.id,
            isExpanded: true,
            warningBorder: !policy.configured,
            options: [
              for (final item in policies)
                ApplePopupSelectOption(
                  value: item.id,
                  label: policyLabel(item),
                ),
            ],
            onChanged: onSelectPolicy,
          ),
        ),
        const SizedBox(width: 6),
        ConversationIconButton(
          key: const Key('agent-orchestration-policy-edit'),
          tooltip: strings.editPolicy,
          onPressed: onEditPolicy,
          icon: Icons.edit_outlined,
        ),
      ],
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
  await controller.saveAgentOrchestrationPolicy(policy);
}
