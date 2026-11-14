import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/collaboration_run_models.dart';
import 'package:licoup/src/frontend/features/collaboration/ui/collaboration_card_model.dart';
import 'package:licoup/src/frontend/features/collaboration/ui/collaboration_graph_layout.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/projections/collaboration/collaboration_projection_producer.dart';

import 'support/collaboration_fixture.dart';

void main() {
  final strings = LicoStrings.forPreference('zh');

  Map<String, CollaborationCardModel> modelsOf(
    CollaborationRunSnapshot snapshot, {
    bool compare = false,
    int? viewedNumber,
    CollaborationGraph? viewedGraph,
  }) {
    final projection = collaborationProjection(
      snapshot: snapshot,
      viewedNumber: viewedNumber,
      viewedGraph: viewedGraph,
    );
    final plan = CollaborationDisplayPlan.of(projection, compare: compare);
    return collaborationCardModels(plan, strings);
  }

  test('sequential actor chains merge into stack cards', () {
    final models = modelsOf(collabSnapshotV2());
    final plan = models['p1'];
    expect(plan, isA<CollaborationStackCardModel>());
    expect((plan! as CollaborationStackCardModel).steps.map((s) => s.nodeId), [
      'p1',
      'p2',
      'p3',
    ]);
    final ship = models['s1']! as CollaborationStackCardModel;
    expect(ship.steps.map((s) => s.nodeId), ['s1', 's2', 's3']);
    expect(ship.headLabel, 'Lead 编排');
    expect(models['fork'], isA<CollaborationConnectorModel>());
    expect(models['done'], isA<CollaborationTerminalModel>());
  });

  test('a fallback switches the card agent and drops the model chip', () {
    final models = modelsOf(collabSnapshotV2());
    final idx = models['idx']! as CollaborationTaskCardModel;
    expect(idx.agentId, 'deepseek-harness');
    expect(idx.agentLabel, 'DeepSeek Harness');
    expect(idx.modelChip, isNull);
    expect(idx.statusLabel, '待你决定');
    final tones = idx.notes.map((note) => note.tone);
    // The escalated gate and the fallback receipt both annotate the card.
    expect(tones, contains(CollaborationNoteTone.warning));
    expect(tones, contains(CollaborationNoteTone.receipt));
  });

  test('an approved gate renders the Lead-approved reason', () {
    final models = modelsOf(collabSnapshotV2());
    final ui = models['ui']! as CollaborationTaskCardModel;
    expect(ui.approvedReason, '低风险：仅安装开发依赖');
    expect(ui.actionLabel, '1 个产物');
  });

  test('tags stay hidden until compare is on', () {
    final without = modelsOf(collabSnapshotV2());
    expect((without['bench']! as CollaborationTaskCardModel).tag, isNull);
    final ship = without['s1']! as CollaborationStackCardModel;
    expect(ship.steps.every((step) => step.tag == null), isTrue);

    final withCompare = modelsOf(collabSnapshotV2(), compare: true);
    final bench = withCompare['bench']! as CollaborationTaskCardModel;
    expect(bench.tag?.label, '+ 新增');
    expect(bench.tag?.tone, CollaborationTagTone.added);
    final steps = (withCompare['s1']! as CollaborationStackCardModel).steps;
    final reassigned = steps.firstWhere((step) => step.nodeId == 's2');
    expect(reassigned.tag?.label, contains('改派'));
    expect(reassigned.tag?.label, contains('Codex'));
    final adjusted = steps.firstWhere((step) => step.nodeId == 's3');
    expect(adjusted.tag?.label, '已调整');
  });

  test('a held proposal renders ghosts, tags and locks', () {
    final models = modelsOf(collabSnapshotWithProposal());
    final bench = models['bench']! as CollaborationTaskCardModel;
    expect(bench.presence, CollaborationPresence.proposed);
    expect(bench.tag?.tone, CollaborationTagTone.proposal);
    final steps = (models['s1']! as CollaborationStackCardModel).steps;
    // Pending steps the proposal changes wait for the decision.
    expect(steps.firstWhere((step) => step.nodeId == 's2').locked, isTrue);
    expect(steps.firstWhere((step) => step.nodeId == 's3').locked, isTrue);
    expect(steps.firstWhere((step) => step.nodeId == 's1').locked, isFalse);
    // Work already under way keeps going while the proposal waits.
    expect((models['idx']! as CollaborationTaskCardModel).locked, isFalse);
  });

  test('a historical revision shows structure only', () {
    final models = modelsOf(
      collabSnapshotV2(),
      viewedNumber: 1,
      viewedGraph: collaborationGraphV1(),
    );
    final idx = models['idx']! as CollaborationTaskCardModel;
    expect(idx.statusLabel, isEmpty);
    expect(idx.actionLabel, isNull);
    expect(idx.tag, isNull);
    expect(idx.notes, isEmpty);
    expect(models.containsKey('bench'), isFalse);
  });

  test('a finished branch waiting on the join says so', () {
    final states = <String, CollaborationNodeState>{
      ...collabStatesV2(),
      'ui': collabState(CollaborationNodeStatus.succeeded, artifactCount: 2),
      'join': collabState(CollaborationNodeStatus.pending),
    };
    final models = modelsOf(collabSnapshotV2(nodeStates: states));
    final ui = models['ui']! as CollaborationTaskCardModel;
    expect(
      ui.notes.any(
        (note) =>
            note.tone == CollaborationNoteTone.muted &&
            note.text == '已提交产物，等待汇合',
      ),
      isTrue,
    );
  });

  test('a stack aggregates the status that needs attention', () {
    final states = <String, CollaborationNodeState>{
      ...collabStatesV2(),
      's1': collabState(CollaborationNodeStatus.running),
      's2': collabState(CollaborationNodeStatus.failed, attempt: 3),
      's3': collabState(CollaborationNodeStatus.pending),
    };
    final models = modelsOf(collabSnapshotV2(nodeStates: states));
    expect(models['s1']!.status, CollaborationNodeStatus.failed);
  });

  test('edge styles mark active routes and added routes in compare', () {
    final projection = collaborationProjection(snapshot: collabSnapshotV2());
    final plan = CollaborationDisplayPlan.of(projection, compare: true);
    final styles = collaborationEdgeStyles(plan);
    // Bench is running behind the finished fork.
    expect(styles['fork>bench>flow']?.active, isTrue);
    expect(styles['fork>bench>flow']?.added, isTrue);
    expect(styles['bench>join>flow']?.added, isTrue);
    // The join has not started, so nothing flows into it.
    expect(styles['ui>join>flow']?.active, isFalse);
    // The review callback routes above as a dashed accent edge.
    expect(styles['arch>idx>callback']?.kind, CollaborationRouteKind.callback);
  });
}
