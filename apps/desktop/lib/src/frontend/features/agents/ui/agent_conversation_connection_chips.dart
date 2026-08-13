import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_pane_presentation.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_parity_disclosure.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_virtual_machine_destination.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Splicable row children rendering the conversation connection affordances:
/// the capability parity disclosure, the virtual-machine destination chip,
/// and the OpenCode serve status chip. The console header splices the result
/// into its identity row; the messaging details panel wraps the same chips in
/// its connection section, so both surfaces render identical affordances.
List<Widget> conversationConnectionChipChildren({
  required TargetCandidate target,
  required AgentConversationServeState? opencodeServeState,
  bool showParity = true,
  double paritySpacing = 10,
  double chipSpacing = 8,
}) {
  return [
    if (showParity) ...[
      SizedBox(width: paritySpacing),
      ConversationParityDisclosurePanel(target: target),
    ],
    if (target.hasValidVirtualMachineConnection) ...[
      SizedBox(width: chipSpacing),
      ConversationVirtualMachineDestinationChip(
        destination: target.virtualMachineDestination,
      ),
    ],
    if (target.target == 'opencode') ...[
      SizedBox(width: chipSpacing),
      OpencodeServeStatusChip(state: opencodeServeState),
    ],
  ];
}

/// Compact status pill for the agent-owned OpenCode serve process.
class OpencodeServeStatusChip extends StatelessWidget {
  const OpencodeServeStatusChip({super.key, required this.state});

  final AgentConversationServeState? state;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final status = state?.status ?? AgentConversationServeStatus.stopped;
    final port = state?.port;
    final label = switch (status) {
      AgentConversationServeStatus.running =>
        port == null ? 'OpenCode serve' : 'OpenCode :$port',
      AgentConversationServeStatus.blocked =>
        state?.portConflict == true
            ? 'OpenCode port blocked'
            : 'OpenCode blocked',
      AgentConversationServeStatus.unavailable => 'OpenCode unavailable',
      _ => 'OpenCode stopped',
    };
    final color = switch (status) {
      AgentConversationServeStatus.running => colors.success,
      AgentConversationServeStatus.blocked ||
      AgentConversationServeStatus.unavailable => colors.error,
      _ => colors.textMuted,
    };
    return Container(
      key: const Key('opencode-serve-status'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
