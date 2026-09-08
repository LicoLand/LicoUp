import 'package:licoup/src/contracts/generated/conversation.g.dart';

/// Typed facts for one parent card and its matching child-list entry.
///
/// This is a constructor bundle of generated DTOs, not a second Goal-state
/// projection. It does not classify speech, synthesize lifecycle, or invent
/// progress percentages.
final class ContinuousAssistantTaskView {
  const ContinuousAssistantTaskView({
    required this.relation,
    required this.progress,
    this.contract,
    this.matter,
    this.childWorkContexts = const <ContinuityWorkContext>[],
  });

  final ContinuityTaskConversationRelation relation;
  final ContinuityGoalProgress progress;
  final ContinuityGoalContract? contract;
  final ContinuityMatter? matter;
  final List<ContinuityWorkContext> childWorkContexts;
}

/// Orders sibling cards by the typed parent-card sequence.
///
/// Same rule as store `events UNIQUE(conversation_id, sequence)` and SQL
/// `ORDER BY sequence, event_id`: integer sequence first, then event id.
/// Status and completion time are not keys. Distinct sequences are required
/// by `admit_sibling_card_order`; the event-id tie-break only stops a
/// programming error from shuffling rows.
List<ContinuousAssistantTaskView> orderContinuousAssistantTasksByCardSequence(
  Iterable<ContinuousAssistantTaskView> tasks,
) {
  final ordered = List<ContinuousAssistantTaskView>.of(tasks);
  ordered.sort((left, right) {
    final bySequence = left.relation.cardAnchor.sequence.compareTo(
      right.relation.cardAnchor.sequence,
    );
    if (bySequence != 0) {
      return bySequence;
    }
    return left.relation.cardAnchor.eventId.compareTo(
      right.relation.cardAnchor.eventId,
    );
  });
  return ordered;
}

/// Collapsed progress text taken only from supplied next-attention / control.
///
/// Does not compute ratios, percentages, or a synthetic "completed" label.
String continuousAssistantCollapsedProgress(ContinuityGoalProgress progress) {
  if (progress.control == ContinuityGoalControl.paused) {
    return progress.control.wireName;
  }
  if (progress.control == ContinuityGoalControl.cancelRequested) {
    return progress.control.wireName;
  }
  return switch (progress.nextAttention) {
    ContinuityNextAttentionWait wait => wait.reviewPolicy,
    ContinuityNextAttentionActiveExecution active => active.executionRef,
    ContinuityNextAttentionDispatchableStep step => step.stepRef,
    null => progress.lifecycle.wireName,
  };
}

bool continuousAssistantLifecycleIsAbsorbing(
  ContinuityGoalLifecycle lifecycle,
) {
  return lifecycle == ContinuityGoalLifecycle.achieved ||
      lifecycle == ContinuityGoalLifecycle.cancelled ||
      lifecycle == ContinuityGoalLifecycle.superseded;
}

String continuousAssistantTaskTitle(ContinuousAssistantTaskView task) {
  final matter = task.matter;
  if (matter != null && matter.label.isNotEmpty) {
    return matter.label;
  }
  final contract = task.contract;
  if (contract != null && contract.expectedResult.isNotEmpty) {
    return contract.expectedResult;
  }
  return task.relation.goalId;
}
