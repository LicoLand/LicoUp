import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/contracts/generated/conversation.g.dart';
import 'package:licoup/src/projections/project_collaboration/collaboration_graph_facts.dart';
import 'package:licoup/src/projections/project_collaboration/project_collaboration.dart';

import '../../continuous_assistant/support/continuous_assistant_test_harness.dart';

CollaborationGoalFact _fact(
  String goalId, {
  String childConversationId = 'conversation:child',
  ContinuityGoalProgress? progress,
  CollaborationRunFact? run,
  CollaborationReviewFact? review,
  CollaborationObservationFact? observation,
  ContinuityWorkContextStatus? workContextStatus,
}) {
  return CollaborationGoalFact(
    relation: testRelation(
      goalId: goalId,
      childConversationId: childConversationId,
      cardAnchor: testCardAnchor(eventId: 'event:$goalId', sequence: 1),
    ),
    progress: progress,
    run: run,
    review: review,
    observation: observation,
    workContextStatus: workContextStatus,
  );
}

void main() {
  const projector = ProjectCollaboration();

  test('a state-only update refreshes its region without a new layout', () {
    final opened = projector.snapshot(
      CollaborationGraphSnapshot(
        epoch: 4,
        goals: <CollaborationGoalFact>[
          _fact(
            'goal:one',
            progress: testProgress(
              goalId: 'goal:one',
              lifecycle: ContinuityGoalLifecycle.active,
            ),
            observation: const CollaborationObservationFact(
              observationCount: 1,
              lastObservationRef: 'observation:one',
            ),
          ),
          _fact(
            'goal:two',
            childConversationId: 'conversation:child-two',
            progress: testProgress(
              goalId: 'goal:two',
              lifecycle: ContinuityGoalLifecycle.waiting,
            ),
          ),
        ],
      ),
    );
    final first = opened.projection;
    expect(first.epoch, 4);
    expect(first.nodes, hasLength(2));

    final applied = projector.apply(
      first,
      CollaborationGraphDelta(
        epoch: 4,
        goals: <CollaborationGoalFact>[
          _fact(
            'goal:two',
            childConversationId: 'conversation:child-two',
            progress: testProgress(
              goalId: 'goal:two',
              lifecycle: ContinuityGoalLifecycle.waiting,
              revision: 2,
              nextAttention: const ContinuityNextAttentionWait(
                triggerRef: 'due:1000',
                reviewPolicy: 'review-due',
                responsibleParty: 'membership:child',
              ),
            ),
            review: const CollaborationReviewFact(
              requiredCriteria: 2,
              satisfiedCriteria: 1,
              rejectedCriteria: 1,
            ),
          ),
        ],
      ),
    );

    expect(applied.reconnected, isFalse);
    expect(
      applied.relayoutRequired,
      isFalse,
      reason: 'a state-only update must not ask for a new graph layout',
    );
    expect(applied.projection.topologyRevision, first.topologyRevision);
    expect(
      identical(applied.projection.node('goal:one'), first.node('goal:one')),
      isTrue,
      reason: 'an untouched region keeps its projected instance',
    );
    final two = applied.projection.node('goal:two');
    expect(two?.revision, 2);
    expect(two?.blockingReason, CollaborationBlockingReason.reviewRejected);
    expect(two?.review.acceptanceComplete, isFalse);
    expect(two?.completed, isFalse);
  });

  test('a topology change asks for layout and keeps surviving node state', () {
    final opened = projector.snapshot(
      CollaborationGraphSnapshot(
        epoch: 7,
        goals: <CollaborationGoalFact>[
          _fact(
            'goal:one',
            progress: testProgress(goalId: 'goal:one', revision: 3),
          ),
        ],
      ),
    );
    final applied = projector.apply(
      opened.projection,
      CollaborationGraphDelta(
        epoch: 7,
        topologyChanged: true,
        goals: <CollaborationGoalFact>[
          _fact(
            'goal:new',
            childConversationId: 'conversation:child-new',
            progress: testProgress(goalId: 'goal:new'),
          ),
        ],
      ),
    );
    expect(applied.relayoutRequired, isTrue);
    expect(applied.reconnected, isFalse);
    expect(
      applied.projection.topologyRevision,
      opened.projection.topologyRevision + 1,
    );
    final surviving = applied.projection.node('goal:one');
    expect(surviving, isNotNull);
    expect(surviving?.revision, 3);
    expect(
      surviving?.topologyRevision,
      applied.projection.topologyRevision,
      reason: 'a surviving node is re-anchored, not rebuilt from scratch',
    );
    expect(applied.projection.node('goal:new'), isNotNull);
  });

  test('a removal is a topology change and drops only the removed region', () {
    final opened = projector.snapshot(
      CollaborationGraphSnapshot(
        epoch: 2,
        goals: <CollaborationGoalFact>[
          _fact('goal:keep', progress: testProgress(goalId: 'goal:keep')),
          _fact(
            'goal:gone',
            childConversationId: 'conversation:child-gone',
            progress: testProgress(goalId: 'goal:gone'),
          ),
        ],
      ),
    );
    final applied = projector.apply(
      opened.projection,
      const CollaborationGraphDelta(
        epoch: 2,
        removedGoalIds: <String>['goal:gone'],
        goals: <CollaborationGoalFact>[],
      ),
    );
    expect(applied.relayoutRequired, isTrue);
    expect(applied.projection.node('goal:gone'), isNull);
    expect(applied.projection.node('goal:keep'), isNotNull);
    expect(applied.projection.nodes, hasLength(1));
  });

  test('reconnect never mixes epochs and never invents completion', () {
    final opened = projector.snapshot(
      CollaborationGraphSnapshot(
        epoch: 1,
        goals: <CollaborationGoalFact>[
          _fact(
            'goal:closed',
            progress: testProgress(
              goalId: 'goal:closed',
              lifecycle: ContinuityGoalLifecycle.achieved,
            ),
          ),
          _fact('goal:open', progress: testProgress(goalId: 'goal:open')),
        ],
      ),
    );
    expect(opened.projection.node('goal:closed')?.completed, isTrue);

    final reconnected = projector.apply(
      opened.projection,
      CollaborationGraphDelta(
        epoch: 9,
        goals: <CollaborationGoalFact>[
          // The new connection knows the identity but has reported no state.
          _fact('goal:closed'),
        ],
      ),
    );
    expect(reconnected.reconnected, isTrue);
    expect(reconnected.relayoutRequired, isTrue);
    expect(reconnected.projection.epoch, 9);
    expect(
      reconnected.projection.node('goal:open'),
      isNull,
      reason: 'another epoch never carries its topology forward',
    );
    final closed = reconnected.projection.node('goal:closed');
    expect(closed?.lifecycle, isNull);
    expect(closed?.control, isNull);
    expect(
      closed?.completed,
      isFalse,
      reason: 'an unreported lifecycle is unknown, not achieved',
    );
    expect(closed?.blockingReason, CollaborationBlockingReason.unreported);
  });

  test('work facts stay independent and report real blocking reasons', () {
    final opened = projector.snapshot(
      CollaborationGraphSnapshot(
        epoch: 3,
        goals: <CollaborationGoalFact>[
          _fact(
            'goal:paused',
            progress: testProgress(
              goalId: 'goal:paused',
              control: ContinuityGoalControl.paused,
            ),
          ),
          _fact(
            'goal:approval',
            childConversationId: 'conversation:child-approval',
            progress: testProgress(goalId: 'goal:approval'),
            run: const CollaborationRunFact(
              activeExecutionRef: 'execution:one',
              approvalWaiting: true,
            ),
          ),
          _fact(
            'goal:lost',
            childConversationId: 'conversation:child-lost',
            progress: testProgress(goalId: 'goal:lost'),
            workContextStatus: ContinuityWorkContextStatus.lost,
          ),
          _fact(
            'goal:running',
            childConversationId: 'conversation:child-running',
            progress: testProgress(
              goalId: 'goal:running',
              nextAttention: const ContinuityNextAttentionActiveExecution(
                executionRef: 'execution:two',
              ),
            ),
            run: const CollaborationRunFact(
              activeExecutionRef: 'execution:two',
            ),
            observation: const CollaborationObservationFact(
              observationCount: 4,
              lastObservationRef: 'observation:four',
            ),
          ),
        ],
      ),
    );
    final nodes = opened.projection;
    expect(
      nodes.node('goal:paused')?.blockingReason,
      CollaborationBlockingReason.paused,
    );
    expect(nodes.node('goal:paused')?.held, isTrue);
    expect(
      nodes.node('goal:approval')?.blockingReason,
      CollaborationBlockingReason.approvalWaiting,
    );
    expect(
      nodes.node('goal:lost')?.blockingReason,
      CollaborationBlockingReason.executorUnknown,
    );
    expect(
      nodes.node('goal:running')?.blockingReason,
      CollaborationBlockingReason.none,
    );
    // A recorded observation changes nothing about the run or the acceptance.
    expect(nodes.node('goal:running')?.observation.observationCount, 4);
    expect(nodes.node('goal:running')?.run.activeExecutionRef, 'execution:two');
    expect(nodes.node('goal:running')?.completed, isFalse);
  });

  test('a late fact cannot rewrite a newer revision', () {
    final opened = projector.snapshot(
      CollaborationGraphSnapshot(
        epoch: 5,
        goals: <CollaborationGoalFact>[
          _fact(
            'goal:one',
            progress: testProgress(goalId: 'goal:one', revision: 4),
          ),
        ],
      ),
    );
    final applied = projector.apply(
      opened.projection,
      CollaborationGraphDelta(
        epoch: 5,
        goals: <CollaborationGoalFact>[
          _fact(
            'goal:one',
            progress: testProgress(
              goalId: 'goal:one',
              revision: 3,
              lifecycle: ContinuityGoalLifecycle.waiting,
            ),
          ),
        ],
      ),
    );
    final node = applied.projection.node('goal:one');
    expect(node?.revision, 4);
    expect(node?.lifecycle, ContinuityGoalLifecycle.active);
    expect(
      identical(node, opened.projection.node('goal:one')),
      isTrue,
      reason: 'a stale revision leaves the projected region untouched',
    );
  });
}
