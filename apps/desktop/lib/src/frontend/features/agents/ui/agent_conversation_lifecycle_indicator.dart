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

const _conversationLifecycleProgressStages = <ConversationTurnLifecycleStage>[
  ConversationTurnLifecycleStage.submitted,
  ConversationTurnLifecycleStage.accepted,
  ConversationTurnLifecycleStage.processing,
  ConversationTurnLifecycleStage.responding,
  ConversationTurnLifecycleStage.completed,
];

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

  int get activeStep {
    if (stage != ConversationTurnLifecycleStage.failed) {
      return _conversationLifecycleProgressStages.indexOf(stage);
    }
    for (
      var index = _conversationLifecycleProgressStages.length - 1;
      index >= 0;
      index--
    ) {
      if (observedStages.contains(
        _conversationLifecycleProgressStages[index],
      )) {
        return index;
      }
    }
    return -1;
  }
}

bool isConversationLifecycleEvent(AgentConversationMessage message) =>
    message.cardType.trim().toLowerCase() == 'lifecycle';

ConversationTurnLifecycleProjection? projectConversationTurnLifecycle(
  Iterable<AgentConversationMessage> events,
) {
  ConversationTurnLifecycleStage? last;
  final observedStages = <ConversationTurnLifecycleStage>{};
  for (final event in events) {
    if (!isConversationLifecycleEvent(event)) continue;
    final stage = _conversationTurnLifecycleStageOf(event);
    if (stage == null) continue;
    _includeConversationLifecycleStage(observedStages, stage);
    for (final observed in _conversationTurnLifecycleStagesFromSubtitle(
      event,
    )) {
      _includeConversationLifecycleStage(observedStages, observed);
    }
    if (stage == ConversationTurnLifecycleStage.failed) {
      last = stage;
      break;
    }
    if (last == null ||
        _conversationLifecycleProgressStages.indexOf(stage) >
            _conversationLifecycleProgressStages.indexOf(last)) {
      last = stage;
    }
    if (stage == ConversationTurnLifecycleStage.completed) break;
  }
  if (last == null) return null;
  return ConversationTurnLifecycleProjection(
    last,
    observedStages: Set.unmodifiable(observedStages),
  );
}

void _includeConversationLifecycleStage(
  Set<ConversationTurnLifecycleStage> target,
  ConversationTurnLifecycleStage stage,
) {
  if (!_conversationLifecycleProgressStages.contains(stage)) return;
  target.add(stage);
}

ConversationTurnLifecycleStage? _conversationTurnLifecycleStageOf(
  AgentConversationMessage event,
) {
  final raw = event.cardTitle.trim().toLowerCase();
  if (!raw.startsWith('lifecycle.')) return null;
  final stageName = raw.substring('lifecycle.'.length);
  return switch (stageName) {
    'submitted' => ConversationTurnLifecycleStage.submitted,
    'accepted' => ConversationTurnLifecycleStage.accepted,
    'processing' => ConversationTurnLifecycleStage.processing,
    'responding' => ConversationTurnLifecycleStage.responding,
    'completed' => ConversationTurnLifecycleStage.completed,
    'failed' => ConversationTurnLifecycleStage.failed,
    _ => null,
  };
}

Set<ConversationTurnLifecycleStage>
_conversationTurnLifecycleStagesFromSubtitle(AgentConversationMessage event) {
  return event.cardSubtitle
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
                  completed: projection.observedStages.contains(
                    _conversationLifecycleProgressStages[index],
                  ),
                  current:
                      projection.stage !=
                          ConversationTurnLifecycleStage.completed &&
                      index == projection.activeStep &&
                      projection.observedStages.contains(
                        _conversationLifecycleProgressStages[index],
                      ),
                  failed:
                      projection.stage ==
                          ConversationTurnLifecycleStage.failed &&
                      index == projection.activeStep &&
                      projection.observedStages.contains(
                        _conversationLifecycleProgressStages[index],
                      ),
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
