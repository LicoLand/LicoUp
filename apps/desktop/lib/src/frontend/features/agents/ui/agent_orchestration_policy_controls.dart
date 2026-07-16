import 'package:flutter/material.dart';

import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/contracts/agent_orchestration_policy.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_orchestration_policy_dialog.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/shared/ui/apple_popup_select.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

export 'package:flutter_client/src/frontend/features/agents/ui/agent_orchestration_policy_dialog.dart';

final class AgentOrchestrationPolicyHeaderControls extends StatelessWidget {
  const AgentOrchestrationPolicyHeaderControls({
    super.key,
    required this.controller,
  });

  final ClientController controller;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final policy = controller.effectiveAgentOrchestrationPolicy;
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
              for (final item in controller.agentOrchestrationPolicies)
                ApplePopupSelectOption(
                  value: item.id,
                  label: controller.agentOrchestrationPolicyDisplayLabel(item),
                ),
            ],
            onChanged: controller.selectAgentOrchestrationPolicy,
          ),
        ),
        const SizedBox(width: 6),
        IconButton(
          key: const Key('agent-orchestration-policy-edit'),
          tooltip: strings.editPolicy,
          onPressed: () =>
              showAgentOrchestrationPolicyEditor(context, controller),
          color: colors.primary,
          hoverColor: Color.lerp(colors.surface, colors.primary, 0.12),
          style: IconButton.styleFrom(
            fixedSize: const Size(36, 36),
            minimumSize: const Size(36, 36),
            padding: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          icon: const Icon(Icons.edit_outlined, size: 18),
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
