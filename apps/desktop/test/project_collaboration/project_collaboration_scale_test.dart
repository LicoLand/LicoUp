import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/presentation_runtime.dart';
import 'package:licoup/src/composition/extensions/project_collaboration_session.dart';
import 'package:licoup/src/presentation/project_collaboration/project_collaboration_surface.dart';
import 'package:licoup/src/projections/project_collaboration/project_collaboration_source.dart';

import 'project_collaboration_scenario.dart';

Future<void> until(bool Function() condition, {String? reason}) async {
  for (var attempt = 0; attempt < 400; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  throw StateError(reason ?? 'condition not reached');
}

void main() {
  test(
    'the frozen budget scale document stays inside every published bound',
    () {
      final document = GraphResourceValue.fromJson(wideScaleDocumentJson());
      expect(document.projects.length, graphResourceMaxProjects);
      expect(document.nodeCount, graphResourceMaxNodes);
      expect(document.edgeCount, graphResourceMaxEdges);
      // The scenario identities the interface observes are present at scale.
      expect(document.node('licoup.node/alpha-build'), isNotNull);
      expect(document.node('licoup.node/alpha-review'), isNotNull);
      final gate = document.index.gateById['licoup.gate/alpha-accept'];
      expect(gate, isNotNull);
      expect(gate!.anchors.length, 2, reason: 'one shared gate, two anchors');
      expect(
        document.index.consumersOf('licoup.node/alpha-build'),
        contains('licoup.node/alpha-review'),
      );
    },
  );

  test('a status-only revision at scale re-lays out nothing', () async {
    final runtime = PresentationRuntime();
    addTearDown(runtime.dispose);
    final source = ProjectCollaborationDocumentSource()
      ..seed(GraphResourceValue.fromJson(wideScaleDocumentJson()));
    final session = ProjectCollaborationSession(
      runtime: runtime,
      source: source,
      owner: SyntheticProjectCollaborationOwner(
        currentRevision: () =>
            source.snapshot?.value.document.planRevision ?? 0,
      ),
    )..start();
    addTearDown(session.dispose);
    await until(() => session.current != null, reason: 'first layout');
    expect(session.stats.layoutRuns, 1);
    expect(
      session.stats.lastWorker!.runsInCallerIsolate,
      isFalse,
      reason: 'the layout ran in a real worker isolate',
    );
    final prepared = session.current!;
    expect(
      prepared.layout.visibleNodeIds.length,
      graphResourceDefaultVisibleNodes,
      reason: 'the visible window is bounded',
    );
    var total = 0;
    for (final summary in prepared.projectSummaries.values) {
      total += summary.total;
    }
    expect(
      total,
      graphResourceMaxNodes,
      reason: 'complete goal counts survive virtualization',
    );

    source.publish(
      GraphResourceValue.fromJson(wideScaleDocumentJson(planRevision: 2)),
      changedNodeIds: <String>{'licoup.node/alpha-build'},
    );
    await until(
      () => session.current?.planRevision == 2,
      reason: 'status update',
    );
    expect(session.stats.layoutRuns, 1, reason: 'no re-layout at scale');
    expect(
      session.stats.lastRecomputedStatuses,
      1,
      reason: 'only the declared unit was recomputed',
    );
    expect(
      session.stats.lastTouchedNodes,
      0,
      reason: 'a status update moves nothing',
    );
    expect(
      session.current!.projectSummaries['licoup.project/alpha']!.total,
      125,
      reason: 'the project totals are complete, not windowed',
    );

    // The negative control: a producer that cannot declare its change set is
    // honestly a full rebuild.
    final published = source.publish(
      GraphResourceValue.fromJson(wideScaleDocumentJson(planRevision: 3)),
    );
    expect(published, isTrue);
    expect(
      source.snapshot!.value.changedNodeIds,
      isNull,
      reason: 'the producer declared nothing',
    );
    await until(
      () => session.current?.planRevision == 3,
      reason: 'undeclared revision installs',
    );
    expect(session.stats.lastRecomputedStatuses, graphResourceMaxNodes);
  });

  test('the action port refuses a stale revision at scale', () async {
    final runtime = PresentationRuntime();
    addTearDown(runtime.dispose);
    final source = ProjectCollaborationDocumentSource()
      ..seed(GraphResourceValue.fromJson(wideScaleDocumentJson()));
    final session = ProjectCollaborationSession(
      runtime: runtime,
      source: source,
      owner: SyntheticProjectCollaborationOwner(
        currentRevision: () =>
            source.snapshot?.value.document.planRevision ?? 0,
      ),
    )..start();
    addTearDown(session.dispose);
    await until(() => session.current != null);
    final receipt = await session.actions.request(
      actionRef: ProjectCollaborationActions.pause,
      revision: 0,
      nodeId: 'licoup.node/alpha-build',
    );
    expect(receipt.accepted, isFalse);
    expect(receipt.code, 'stale_revision');
  });
}
