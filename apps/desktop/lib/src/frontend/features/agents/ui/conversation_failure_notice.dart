import 'package:flutter/material.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/shared/ui/lico_pane_card.dart';
import 'package:licoup/src/frontend/features/agents/ui/conversation_execution_entry.dart';

import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';

/// Visible failure evidence, outside the execution record viewer. No maximum
/// line count hides the stage or cause of an unsuccessful turn.
class ConversationFailureNotice extends StatelessWidget {
  const ConversationFailureNotice({
    super.key,
    required this.message,
    required this.target,
  });

  final AgentConversationMessage message;
  final TargetCandidate target;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final lifecycle = message.cardType == 'lifecycle';
    final label = lifecycle
        ? LicoStrings.of(context).lifecycleFailed
        : message.text;
    return Row(
      key: const Key('conversation-turn-failure'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(
            Icons.error_outline_rounded,
            size: 16,
            color: colors.error,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            style: TextStyle(color: colors.error, fontSize: 13, height: 1.4),
          ),
        ),
        ConversationExecutionMenu(message: message, target: target),
      ],
    );
  }
}

/// Centered system capsule mirroring the site's `.sys-pill`: muted text on a
/// subtle surface with a hairline border, so membership and lifecycle notices
/// read as ambient rows rather than bare text.
class ConversationNotice extends StatelessWidget {
  const ConversationNotice({super.key, required this.message});
  final AgentConversationMessage message;
  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Center(
      child: Container(
        key: const Key('conversation-domain-notice'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: continuousHairlineDecoration(
          color: colors.isDark
              ? colors.background
              : (colors.isDark
                    ? LicoPaneGlass.contentInnerCardFill
                    : colors.surfaceLow),
          borderRadius: BorderRadius.circular(999),
          stroke: colors.line,
        ),
        child: Text(
          message.text,
          textAlign: TextAlign.center,
          style: TextStyle(color: colors.textMuted, fontSize: 11, height: 1.4),
        ),
      ),
    );
  }
}
