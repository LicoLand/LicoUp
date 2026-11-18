import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/collaboration_run_models.dart';
import 'package:licoup/src/presentation/collaboration/collaboration_projection.dart';
import 'package:licoup/src/projections/collaboration/collaboration_projection_producer.dart';

import 'support/collaboration_fixture.dart';

void main() {
  test('a null snapshot reports no run', () {
    final projection = collaborationProjection(snapshot: null);
    expect(projection.availability, CollaborationAvailability.none);
    expect(projection.isActive, isFalse);
  });

  test('progress counts succeeded actor and workset nodes over the head', () {
    final projection = collaborationProjection(snapshot: collabSnapshotV2());
    expect(projection.isActive, isTrue);
    // Actors only: p1..p3 (3) + idx, ui, bench, arch (4) + s1..s3 (3) = 10
    // work nodes; succeeded = p1,p2,p3 + ui = 4.
    expect(projection.totalWork, 10);
    expect(projection.succeededWork, 4);
    expect(projection.status, CollaborationRunStatus.waiting);
    expect(projection.viewedNumber, 2);
    expect(projection.viewingHead, isTrue);
    expect(projection.nodeStates, isNotEmpty);
  });

  test('revisions come newest first', () {
    final snapshot = CollaborationRunSnapshot(
      runId: 'run-1',
      conversationId: 'conv-1',
      status: CollaborationRunStatus.running,
      startedAt: 0,
      updatedAt: 0,
      planChangePolicy: CollaborationPlanChangePolicy.auto,
      gateReviewPolicy: CollaborationGateReviewPolicy.assistant,
      headNumber: 3,
      revisions: [collabRevisionV1(), collabRevisionV2(), collabRevisionV3()],
      graph: collaborationGraphV1(),
      nodeStates: const {},
    );
    final projection = collaborationProjection(snapshot: snapshot);
    expect(projection.revisions.map((revision) => revision.number), [3, 2, 1]);
    expect(projection.head?.number, 3);
  });

  test('a historical view drops live node states and keeps the graph', () {
    final projection = collaborationProjection(
      snapshot: collabSnapshotV2(),
      viewedNumber: 1,
      viewedGraph: collaborationGraphV1(),
    );
    expect(projection.viewingHead, isFalse);
    expect(projection.viewedNumber, 1);
    expect(projection.nodeStates, isEmpty);
    expect(projection.graph?.nodes.any((n) => n.id == 'bench'), isFalse);
    expect(projection.graph?.nodes, hasLength(12));
  });

  test('viewing the head explicitly keeps states', () {
    final projection = collaborationProjection(
      snapshot: collabSnapshotV2(),
      viewedNumber: 2,
      viewedGraph: collaborationGraphV1(),
    );
    expect(projection.viewingHead, isTrue);
    expect(projection.nodeStates, isNotEmpty);
    expect(identical(projection.graph, isNull), isFalse);
    expect(projection.graph?.nodes, hasLength(13));
  });

  test('proposal and head diff map through', () {
    final projection = collaborationProjection(
      snapshot: collabSnapshotWithProposal(),
    );
    expect(projection.proposal, isNotNull);
    expect(projection.proposal?.revision.number, 2);
    expect(projection.proposal?.diff.addedNodes, ['bench']);
    expect(projection.planChangePolicy, CollaborationPlanChangePolicy.ask);
    expect(projection.viewedNumber, 1);
  });

  test('policy changes reflect on the projection', () {
    final projection = collaborationProjection(
      snapshot: collabSnapshotV2(
        gateReviewPolicy: CollaborationGateReviewPolicy.user,
      ),
    );
    expect(projection.gateReviewPolicy, CollaborationGateReviewPolicy.user);
  });
}
