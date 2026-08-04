import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

enum ConversationTurnLifecycleStage {
  submitted,
  accepted,
  processing,
  responding,
  completed,
  failed,
}

final class ConversationTurnLifecycleProjection {
  const ConversationTurnLifecycleProjection(
    this.stage, {
    required this.observedStages,
  });

  final ConversationTurnLifecycleStage stage;
  final Set<ConversationTurnLifecycleStage> observedStages;

  bool get terminal =>
      stage == ConversationTurnLifecycleStage.completed ||
      stage == ConversationTurnLifecycleStage.failed;

  int get activeStep => switch (stage) {
    ConversationTurnLifecycleStage.submitted => 0,
    ConversationTurnLifecycleStage.accepted => 1,
    ConversationTurnLifecycleStage.processing => 2,
    ConversationTurnLifecycleStage.responding => 3,
    ConversationTurnLifecycleStage.completed => 4,
    ConversationTurnLifecycleStage.failed => 2,
  };
}

bool isConversationLifecycleEvent(AgentConversationMessage message) =>
    message.cardType.trim().toLowerCase() == 'lifecycle';

ConversationTurnLifecycleProjection? projectConversationTurnLifecycle(
  Iterable<AgentConversationMessage> events,
) {
  AgentConversationMessage? lifecycle;
  for (final event in events) {
    if (isConversationLifecycleEvent(event)) lifecycle = event;
  }
  if (lifecycle == null) return null;
  final raw = lifecycle.cardTitle.trim().toLowerCase();
  final stageName = raw.startsWith('lifecycle.')
      ? raw.substring('lifecycle.'.length)
      : lifecycle.text.trim().toLowerCase();
  final stage = switch (stageName) {
    'submitted' => ConversationTurnLifecycleStage.submitted,
    'accepted' => ConversationTurnLifecycleStage.accepted,
    'processing' => ConversationTurnLifecycleStage.processing,
    'responding' => ConversationTurnLifecycleStage.responding,
    'completed' => ConversationTurnLifecycleStage.completed,
    'failed' => ConversationTurnLifecycleStage.failed,
    _ => null,
  };
  if (stage == null) return null;
  final observedStages = lifecycle.cardSubtitle
      .split(',')
      .map(
        (value) => switch (value.trim().toLowerCase()) {
          'submitted' => ConversationTurnLifecycleStage.submitted,
          'accepted' => ConversationTurnLifecycleStage.accepted,
          'processing' => ConversationTurnLifecycleStage.processing,
          'responding' => ConversationTurnLifecycleStage.responding,
          'completed' => ConversationTurnLifecycleStage.completed,
          _ => null,
        },
      )
      .whereType<ConversationTurnLifecycleStage>()
      .toSet();
  return ConversationTurnLifecycleProjection(
    stage,
    observedStages: Set.unmodifiable(observedStages),
  );
}

String conversationLifecycleStageLabel(
  ConversationTurnLifecycleStage stage,
  LicoStrings strings,
) => switch (stage) {
  ConversationTurnLifecycleStage.submitted => strings.lifecycleSubmitted,
  ConversationTurnLifecycleStage.accepted => strings.lifecycleAccepted,
  ConversationTurnLifecycleStage.processing => strings.lifecycleProcessing,
  ConversationTurnLifecycleStage.responding => strings.lifecycleResponding,
  ConversationTurnLifecycleStage.completed => strings.lifecycleCompleted,
  ConversationTurnLifecycleStage.failed => strings.lifecycleFailed,
};

class ConversationLifecycleSteps extends StatelessWidget {
  const ConversationLifecycleSteps({super.key, required this.projection});

  final ConversationTurnLifecycleProjection projection;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final labels = <String>[
      strings.lifecycleSubmittedShort,
      strings.lifecycleAcceptedShort,
      strings.lifecycleProcessingShort,
      strings.lifecycleRespondingShort,
      strings.lifecycleCompletedShort,
    ];
    return Semantics(
      key: const Key('conversation-lifecycle-rail'),
      label: conversationLifecycleStageLabel(projection.stage, strings),
      child: ExcludeSemantics(
        child: Row(
          children: [
            for (var index = 0; index < labels.length; index++)
              Expanded(
                child: _ConversationLifecycleStep(
                  label: labels[index],
                  first: index == 0,
                  last: index == labels.length - 1,
                  completed:
                      projection.observedStages.contains(
                        ConversationTurnLifecycleStage.values[index],
                      ) &&
                      (projection.terminal || index < projection.activeStep),
                  current:
                      projection.stage !=
                          ConversationTurnLifecycleStage.completed &&
                      index == projection.activeStep,
                  failed:
                      projection.stage ==
                          ConversationTurnLifecycleStage.failed &&
                      index == projection.activeStep,
                  // Neutral progress chrome — primary/lemon reads as 泛黄 in
                  // the messaging transcript (same family as user-bubble glow).
                  accent: colors.text,
                  muted: colors.line,
                  text: colors.textMuted,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ConversationLifecycleStep extends StatelessWidget {
  const _ConversationLifecycleStep({
    required this.label,
    required this.first,
    required this.last,
    required this.completed,
    required this.current,
    required this.failed,
    required this.accent,
    required this.muted,
    required this.text,
  });

  final String label;
  final bool first;
  final bool last;
  final bool completed;
  final bool current;
  final bool failed;
  final Color accent;
  final Color muted;
  final Color text;

  @override
  Widget build(BuildContext context) {
    final activeColor = failed ? context.licoColors.error : accent;
    final lineColor = completed || current ? activeColor : muted;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Divider(
                height: 1,
                color: first ? Colors.transparent : lineColor,
              ),
            ),
            AnimatedContainer(
              key: Key('conversation-lifecycle-step-$label'),
              duration: const Duration(milliseconds: 180),
              width: current ? 10 : 8,
              height: current ? 10 : 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: completed || current ? activeColor : muted,
                border: current
                    ? Border.all(color: activeColor.withAlpha(80), width: 2)
                    : null,
              ),
            ),
            Expanded(
              child: Divider(
                height: 1,
                color: last ? Colors.transparent : lineColor,
              ),
            ),
          ],
        ),
        const SizedBox(height: 5),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: completed || current ? activeColor : text,
            fontSize: 10.5,
            fontWeight: current ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ],
    );
  }
}
