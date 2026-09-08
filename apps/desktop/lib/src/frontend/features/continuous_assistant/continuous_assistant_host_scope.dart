import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/generated/conversation.g.dart';
import 'package:licoup/src/frontend/features/continuous_assistant/continuous_assistant_command_intent.dart';
import 'package:licoup/src/frontend/features/continuous_assistant/continuous_assistant_task_view.dart';

/// Host commands and child open, available to timeline cards.
final class ContinuousAssistantHostScope extends InheritedWidget {
  const ContinuousAssistantHostScope({
    super.key,
    required this.conversationId,
    required this.onCommand,
    required this.onOpenChild,
    this.progressByGoalId = const <String, ContinuityGoalProgress>{},
    required super.child,
  });

  final String conversationId;
  final ValueChanged<ContinuousAssistantCommandIntent> onCommand;
  final ValueChanged<String> onOpenChild;
  final Map<String, ContinuityGoalProgress> progressByGoalId;

  static ContinuousAssistantHostScope? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<ContinuousAssistantHostScope>();
  }

  @override
  bool updateShouldNotify(ContinuousAssistantHostScope oldWidget) {
    return oldWidget.conversationId != conversationId ||
        !identical(oldWidget.progressByGoalId, progressByGoalId);
  }

  ContinuityGoalProgress? progressFor(String goalId) =>
      progressByGoalId[goalId];
}

Map<String, ContinuityGoalProgress> continuousAssistantProgressByGoalId(
  Iterable<Map<String, dynamic>> taskViews,
) {
  final byGoal = <String, ContinuityGoalProgress>{};
  for (final view in taskViews) {
    final raw = view['progress'];
    if (raw is! Map) continue;
    try {
      final progress = ContinuityGoalProgress.parse(raw);
      if (progress.goalId.isNotEmpty) {
        byGoal[progress.goalId] = progress;
      }
    } on Object {
      continue;
    }
  }
  return Map<String, ContinuityGoalProgress>.unmodifiable(byGoal);
}

ContinuousAssistantTaskView? continuousAssistantTaskFromCardMetadata({
  required Map<String, dynamic> metadata,
  required String parentConversationId,
  required String eventId,
  required int sequence,
  String? partId,
}) {
  final goalId = (metadata['goalId'] ?? '').toString().trim();
  final childId = (metadata['childConversationId'] ?? '').toString().trim();
  if (goalId.isEmpty || childId.isEmpty) {
    return null;
  }
  final lifecycle = ContinuityGoalLifecycle.fromWire(metadata['toLifecycle']);
  final parsedSequence = int.tryParse((metadata['sequence'] ?? '').toString());
  return ContinuousAssistantTaskView(
    relation: ContinuityTaskConversationRelation(
      goalId: goalId,
      parentConversationId: parentConversationId,
      childConversationId: childId,
      cardAnchor: ContinuityParentCardAnchor(
        parentConversationId: parentConversationId,
        eventId: eventId,
        sequence: parsedSequence ?? sequence,
        partId: partId,
      ),
      listingKind: ContinuityTaskListingKind.childTask,
      followThroughKind: ContinuityFollowThroughKind.durable,
      revision: 1,
      createdEvent: ContinuitySourceRef(
        ownerKind: ContinuitySourceOwnerKind.event,
        opaqueId: eventId,
        partId: partId,
        sourceRevision: sequence,
        digest: 'event:$eventId',
        visibilityScope: ContinuityVisibilityScope.conversation,
        validity: ContinuitySourceValidity.current,
      ),
    ),
    progress: ContinuityGoalProgress(
      goalId: goalId,
      revision: 1,
      lifecycle: lifecycle == ContinuityGoalLifecycle.unrecognized
          ? ContinuityGoalLifecycle.active
          : lifecycle,
      control: ContinuityGoalControl.enabled,
      criterionEvidenceRefs: const <ContinuityEvidenceRef>[],
      activeExecutionRefs: const <String>[],
      blockers: const <String>[],
    ),
  );
}
