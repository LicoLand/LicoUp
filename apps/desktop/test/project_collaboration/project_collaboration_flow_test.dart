import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_flutter/presentation_flutter.dart';
import 'package:presentation_runtime/presentation_runtime.dart';
import 'package:licoup/src/composition/extensions/extension_ui_composition.dart';
import 'package:licoup/src/composition/extensions/project_collaboration_composition.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/features/project_collaboration/ui/project_collaboration_page.dart';
import 'package:licoup/src/presentation/project_collaboration/project_collaboration_surface.dart';

import 'project_collaboration_scenario.dart';

Future<void> pumpExtension(
  WidgetTester tester,
  ProjectCollaborationExtension extension, {
  Size size = const Size(1400, 900),
}) async {
  await tester.binding.setSurfaceSize(size);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: extension.buildLayer(
          key: const Key('project-collaboration-host'),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Releases the pipeline and drains its workers inside the test body.
///
/// The binding refuses to end a test with pending timers, so the pool's
/// shutdown handshake is completed here through real asynchronous waits instead
/// of only advancing fake time.
Future<void> drainWorkers(
  WidgetTester tester,
  ExtensionUiComposition composition,
  PresentationRuntime runtime,
) async {
  composition.dispose();
  for (var frame = 0; frame < 60; frame++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 10));
  }
  runtime.dispose();
  await tester.pump(const Duration(milliseconds: 100));
}

/// The mounted project collaboration contribution, if the current epoch has it.
ExtensionUiContributionSession? mountedCollaboration(
  ExtensionUiComposition composition,
) {
  for (final session in composition.registry.mounted) {
    if (session.contribution.id == projectCollaborationContributionId) {
      return session;
    }
  }
  return null;
}

/// Waits until [condition] holds, letting real asynchronous work (worker
/// isolates and real timers) proceed between frames.
Future<void> until(
  WidgetTester tester,
  bool Function() condition, {
  String? reason,
}) async {
  // Generous real-time budget: a loaded machine can delay a worker isolate far
  // beyond the product's own responsiveness, and a test bound is not a
  // product timeout.
  for (var attempt = 0; attempt < 1200; attempt++) {
    if (condition()) {
      await tester.pump();
      return;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  throw StateError(reason ?? 'condition not reached');
}

void main() {
  testWidgets('the mounted contribution renders admitted graph revisions', (
    tester,
  ) async {
    final runtime = PresentationRuntime();
    addTearDown(runtime.dispose);
    final composition = ExtensionUiComposition(runtime: runtime);
    addTearDown(composition.dispose);
    late final ProjectCollaborationExtension extension;
    extension = ProjectCollaborationExtension.mount(
      composition: composition,
      owner: SyntheticProjectCollaborationOwner(
        currentRevision: () =>
            extension.source.snapshot?.value.document.planRevision ?? 0,
      ),
    );
    extension.source.seed(
      GraphResourceValue.fromJson(threeProjectDocumentJson()),
    );
    extension
      ..start()
      ..publishEpoch();
    await pumpExtension(tester, extension);
    await until(tester, () => extension.session.current != null);
    expect(
      find.byKey(const Key('project-collaboration-page')),
      findsNothing,
      reason: 'the contribution mounts through the host, not the page',
    );
    expect(
      find.byKey(
        const Key('project-collaboration-node-licoup.node/alpha-build'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const Key('project-collaboration-canvas-summary-licoup.project/alpha'),
      ),
      findsOneWidget,
    );
    // The mounted surface reads the host text, not its own copy.
    expect(find.text('Projects'), findsOneWidget);
    // The application locale is what the layer resolves its text from, exactly
    // as the real window does.
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        supportedLocales: LicoStrings.supportedLocales,
        localizationsDelegates: const <LocalizationsDelegate<Object>>[
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        home: Scaffold(
          body: extension.buildLayer(
            key: const Key('project-collaboration-host-zh'),
          ),
        ),
      ),
    );
    await until(
      tester,
      () => find.text('项目').evaluate().isNotEmpty,
      reason: 'the host language reaches the mounted surface',
    );
    expect(extension.session.stats.layoutRuns, 1);
  });

  testWidgets('a format this shell does not compile is refused locally and '
      'leaves its siblings mounted', (tester) async {
    final runtime = PresentationRuntime();
    addTearDown(runtime.dispose);
    final composition = ExtensionUiComposition(runtime: runtime);
    addTearDown(composition.dispose);
    late final ProjectCollaborationExtension extension;
    extension = ProjectCollaborationExtension.mount(
      composition: composition,
      owner: SyntheticProjectCollaborationOwner(currentRevision: () => 1),
    );
    extension.source.seed(
      GraphResourceValue.fromJson(threeProjectDocumentJson()),
    );
    extension
      ..start()
      ..publishEpoch();
    await pumpExtension(tester, extension);
    await until(tester, () => extension.session.current != null);

    final futureEpoch = Map<String, Object?>.of(
      ProjectCollaborationExtension.epochDocument(registryEpoch: 2),
    );
    final contributions = (futureEpoch['contributions']! as List<Object?>)
        .cast<Object?>();
    contributions.add(<String, Object?>{
      'schema': extensionUiContributionSchema,
      'id': 'licoup.project-collaboration/future',
      'instanceId': 'licoup.project-collaboration',
      'generation': 1,
      'kind': 'resource-view',
      'title': 'Future graph',
      'resourceRef': projectCollaborationResourceRef,
      'actionRef': projectCollaborationActionRef,
      'resourceFormat': 'licoup.ui.graph-resource.v9',
    });
    contributions.add(<String, Object?>{
      'schema': extensionUiContributionSchema,
      'id': 'licoup.local/refresh',
      'instanceId': 'licoup.project-collaboration',
      'generation': 1,
      'kind': 'command',
      'title': 'Refresh',
    });
    composition.mountDocument(futureEpoch);
    await until(
      tester,
      () => mountedCollaboration(composition)?.graph?.current != null,
      reason: 'the v1 renderer re-mounts in the new epoch',
    );
    expect(
      find.byKey(
        const Key('project-collaboration-node-licoup.node/alpha-build'),
      ),
      findsOneWidget,
      reason: 'the compiled v1 renderer still mounts',
    );
    final futureDecision = composition.registry.decisions.firstWhere(
      (decision) =>
          decision.contribution.id == 'licoup.project-collaboration/future',
    );
    expect(
      futureDecision.blocked,
      ExtensionUiMountBlock.resourceFormatUnavailable,
      reason: 'the unknown format is refused locally and preserved',
    );
    expect(
      composition.registry.decisions
          .firstWhere(
            (decision) =>
                decision.contribution.id == projectCollaborationContributionId,
          )
          .isMounted,
      isTrue,
      reason: 'the v1 renderer still mounts',
    );
    expect(
      find.byKey(const Key('extension-command-licoup.local/refresh')),
      findsOneWidget,
      reason: 'an unrelated contribution is untouched',
    );
    await drainWorkers(tester, composition, runtime);
  });

  testWidgets('a status-only revision updates in place without re-layout', (
    tester,
  ) async {
    final runtime = PresentationRuntime();
    addTearDown(runtime.dispose);
    final composition = ExtensionUiComposition(runtime: runtime);
    addTearDown(composition.dispose);
    late final ProjectCollaborationExtension extension;
    extension = ProjectCollaborationExtension.mount(
      composition: composition,
      owner: SyntheticProjectCollaborationOwner(
        currentRevision: () =>
            extension.source.snapshot?.value.document.planRevision ?? 0,
      ),
    );
    extension.source.seed(
      GraphResourceValue.fromJson(threeProjectDocumentJson()),
    );
    extension
      ..start()
      ..publishEpoch();
    await pumpExtension(tester, extension);
    await until(tester, () => extension.session.current != null);
    extension.source.publish(
      GraphResourceValue.fromJson(threeProjectDocumentJson(planRevision: 2)),
      changedNodeIds: <String>{'licoup.node/alpha-build'},
    );
    await until(tester, () => extension.session.current?.planRevision == 2);
    expect(extension.session.stats.layoutRuns, 1);
    expect(extension.session.stats.statusMerges, greaterThanOrEqualTo(1));
    expect(extension.session.stats.lastRecomputedStatuses, 1);
    expect(
      find.byKey(
        const Key('project-collaboration-lane-summary-licoup.lane/build'),
      ),
      findsOneWidget,
    );
    await drainWorkers(tester, composition, runtime);
  });

  testWidgets('an undeclared change set is a visible full rebuild, not a '
      'locality claim', (tester) async {
    final runtime = PresentationRuntime();
    addTearDown(runtime.dispose);
    final composition = ExtensionUiComposition(runtime: runtime);
    addTearDown(composition.dispose);
    late final ProjectCollaborationExtension extension;
    extension = ProjectCollaborationExtension.mount(
      composition: composition,
      owner: SyntheticProjectCollaborationOwner(currentRevision: () => 1),
    );
    extension.source.seed(
      GraphResourceValue.fromJson(threeProjectDocumentJson()),
    );
    extension
      ..start()
      ..publishEpoch();
    await pumpExtension(tester, extension);
    await until(tester, () => extension.session.current != null);
    extension.source.publish(
      GraphResourceValue.fromJson(threeProjectDocumentJson(planRevision: 2)),
    );
    await until(tester, () => extension.session.current?.planRevision == 2);
    expect(extension.session.stats.layoutRuns, 1, reason: 'no re-layout');
    expect(
      extension.session.stats.lastRecomputedStatuses,
      extension.session.current!.document.nodeCount,
      reason: 'an undeclared change set honestly recomputes every status',
    );
    await drainWorkers(tester, composition, runtime);
  });

  testWidgets(
    'withdrawing authority hides labels, counts and anchors at once',
    (tester) async {
      final runtime = PresentationRuntime();
      addTearDown(runtime.dispose);
      final composition = ExtensionUiComposition(runtime: runtime);
      addTearDown(composition.dispose);
      late final ProjectCollaborationExtension extension;
      extension = ProjectCollaborationExtension.mount(
        composition: composition,
        owner: SyntheticProjectCollaborationOwner(currentRevision: () => 1),
      );
      extension.source.seed(
        GraphResourceValue.fromJson(threeProjectDocumentJson()),
      );
      extension
        ..start()
        ..publishEpoch();
      await pumpExtension(tester, extension);
      await until(tester, () => extension.session.current != null);
      expect(
        find.byKey(const Key('project-collaboration-gate-count')),
        findsNothing,
      );
      runtime.revoke(extension.source.fieldGroup.resource);
      await until(tester, () => extension.session.current == null);
      expect(
        find.byKey(
          const Key('project-collaboration-node-licoup.node/alpha-build'),
        ),
        findsNothing,
      );
      expect(
        find.byKey(const Key('project-collaboration-unavailable')),
        findsOneWidget,
      );
      await drainWorkers(tester, composition, runtime);
    },
  );

  testWidgets('a committed epoch after a withdrawal restores the surface from '
      'a fresh snapshot', (tester) async {
    final runtime = PresentationRuntime();
    addTearDown(runtime.dispose);
    final composition = ExtensionUiComposition(runtime: runtime);
    addTearDown(composition.dispose);
    late final ProjectCollaborationExtension extension;
    extension = ProjectCollaborationExtension.mount(
      composition: composition,
      owner: SyntheticProjectCollaborationOwner(currentRevision: () => 1),
    );
    extension.source.seed(
      GraphResourceValue.fromJson(threeProjectDocumentJson()),
    );
    extension
      ..start()
      ..publishEpoch();
    await pumpExtension(tester, extension);
    await until(tester, () => extension.session.current != null);

    composition.withdraw();
    await tester.pumpAndSettle();
    expect(
      find.byKey(
        const Key('project-collaboration-node-licoup.node/alpha-build'),
      ),
      findsNothing,
    );
    extension.publishEpoch(registryEpoch: 2);
    await until(
      tester,
      () => mountedCollaboration(composition)?.graph?.current != null,
      reason: 'the reconnected surface reads the current snapshot',
    );
    expect(mountedCollaboration(composition)!.identity.registryEpoch, 2);
    expect(
      find.byKey(
        const Key('project-collaboration-node-licoup.node/alpha-build'),
      ),
      findsOneWidget,
    );
    await drainWorkers(tester, composition, runtime);
  });

  testWidgets('disposing the view does not cancel admitted preparation', (
    tester,
  ) async {
    final runtime = PresentationRuntime();
    addTearDown(runtime.dispose);
    final composition = ExtensionUiComposition(runtime: runtime);
    late final ProjectCollaborationExtension extension;
    extension = ProjectCollaborationExtension.mount(
      composition: composition,
      owner: SyntheticProjectCollaborationOwner(currentRevision: () => 1),
    );
    extension.source.seed(
      GraphResourceValue.fromJson(threeProjectDocumentJson()),
    );
    extension
      ..start()
      ..publishEpoch();
    await pumpExtension(tester, extension);
    await until(tester, () => extension.session.current != null);
    expect(extension.session.stats.layoutRuns, 1);

    // A topology change starts a layout, then the view goes away.
    extension.source.publish(
      GraphResourceValue.fromJson(threeProjectDocumentJson(planRevision: 2)),
      topologyChanged: true,
      changedNodeIds: <String>{'licoup.node/alpha-build'},
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await until(
      tester,
      () => extension.session.stats.layoutRuns == 2,
      reason: 'the admitted layout finished after the view was disposed',
    );
    expect(
      extension.session.current?.planRevision,
      2,
      reason: 'the prepared value is installed for the next viewer',
    );
    await drainWorkers(tester, composition, runtime);
  });

  testWidgets('the mounted contribution dispatches with the admitted plan '
      'revision and surfaces the withdrawal reason', (tester) async {
    final runtime = PresentationRuntime();
    addTearDown(runtime.dispose);
    final composition = ExtensionUiComposition(runtime: runtime);
    late final ProjectCollaborationExtension extension;
    final owner = SyntheticProjectCollaborationOwner(
      currentRevision: () =>
          extension.source.snapshot?.value.document.planRevision ?? 0,
    );
    extension = ProjectCollaborationExtension.mount(
      composition: composition,
      owner: owner,
    );
    extension.source.seed(
      GraphResourceValue.fromJson(threeProjectDocumentJson(planRevision: 5)),
    );
    extension
      ..start()
      ..publishEpoch();
    await pumpExtension(tester, extension);
    await until(tester, () => extension.session.current != null);
    final session = mountedCollaboration(composition)!;
    expect(session.graph?.current, isNotNull);

    // The renderer asks the mounted session for an action; the session must
    // cite the admitted plan revision the user saw.
    await session.dispatchGraphAction(
      const GraphActionRequest(
        actionRef: ProjectCollaborationActions.pause,
        nodeId: 'licoup.node/alpha-build',
      ),
    );
    expect(
      owner.performed.last,
      ProjectCollaborationActions.pause,
      reason: 'the owner saw the request with the real revision',
    );
    expect(
      extension.session.actions.receipts.last.accepted,
      isTrue,
      reason: 'a request citing the admitted revision is accepted',
    );
    expect(extension.session.actions.receipts.last.revision, 5);

    // A withdrawn authority names its own cause on the mounted path.
    runtime.revoke(extension.source.fieldGroup.resource);
    await until(
      tester,
      () => session.graph?.current == null,
      reason: 'the mounted frame drops',
    );
    expect(session.graph?.localUnavailableReason, 'source_unavailable');
    // The mounted surface names the cause in the interface language instead of
    // printing the internal reason code.
    expect(
      find.descendant(
        of: find.byKey(const Key('project-collaboration-unavailable')),
        matching: find.textContaining('no longer available'),
      ),
      findsOneWidget,
      reason: 'the mounted surface displays the real reason',
    );
    await drainWorkers(tester, composition, runtime);
  });

  testWidgets('an action without a native owner is refused, never faked', (
    tester,
  ) async {
    final runtime = PresentationRuntime();
    addTearDown(runtime.dispose);
    final composition = ExtensionUiComposition(runtime: runtime);
    addTearDown(composition.dispose);
    late final ProjectCollaborationExtension extension;
    extension = ProjectCollaborationExtension.mount(composition: composition);
    extension.source.seed(
      GraphResourceValue.fromJson(threeProjectDocumentJson()),
    );
    extension
      ..start()
      ..publishEpoch();
    await pumpExtension(tester, extension);
    await until(tester, () => extension.session.current != null);
    final receipt = await extension.session.actions.request(
      actionRef: ProjectCollaborationActions.pause,
      nodeId: 'licoup.node/alpha-build',
    );
    expect(receipt.accepted, isFalse);
    expect(receipt.code, 'project_collaboration_unavailable');
    Future<void> showPage(ProjectCollaborationExtension surface) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProjectCollaborationPage(surface: surface.session),
          ),
        ),
      );
      await tester.pump();
    }

    final insert = find.byKey(const Key('project-collaboration-insert'));
    await showPage(extension);
    expect(extension.session.canRequestActions, isFalse);
    expect(
      tester.widget<FilledButton>(insert).onPressed,
      isNull,
      reason: 'a read-only document does not imply an action owner',
    );
    expect(
      extension
          .session
          .current!
          .statusById['licoup.node/alpha-build']!
          .execution,
      GraphExecutionState.running,
      reason: 'a refusal changes no projected state',
    );

    final ownedRuntime = PresentationRuntime();
    final ownedComposition = ExtensionUiComposition(runtime: ownedRuntime);
    final owned = ProjectCollaborationExtension.mount(
      composition: ownedComposition,
      owner: SyntheticProjectCollaborationOwner(currentRevision: () => 1),
    );
    expect(
      owned.session.canRequestActions,
      isFalse,
      reason: 'an owner without an admitted document is not available',
    );
    owned.source.seed(GraphResourceValue.fromJson(threeProjectDocumentJson()));
    owned.start();
    await until(tester, () => owned.session.current != null);
    await showPage(owned);
    expect(owned.session.canRequestActions, isTrue);
    expect(tester.widget<FilledButton>(insert).onPressed, isNotNull);

    await showPage(extension);
    expect(
      tester.widget<FilledButton>(insert).onPressed,
      isNull,
      reason: 'replacing the surface cannot inherit the old owner availability',
    );
    await showPage(owned);
    ownedRuntime.revoke(owned.source.fieldGroup.resource);
    await tester.pump();
    expect(owned.session.canRequestActions, isFalse);
    expect(
      tester.widget<FilledButton>(insert).onPressed,
      isNull,
      reason: 'withdrawal disables Insert through the existing display stream',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    owned.session.dispose();
    await drainWorkers(tester, ownedComposition, ownedRuntime);
    await drainWorkers(tester, composition, runtime);
  });

  testWidgets('takeover renders the native refusal and nothing else', (
    tester,
  ) async {
    final runtime = PresentationRuntime();
    addTearDown(runtime.dispose);
    final composition = ExtensionUiComposition(runtime: runtime);
    addTearDown(composition.dispose);
    late final ProjectCollaborationExtension extension;
    final owner = SyntheticProjectCollaborationOwner(
      currentRevision: () => 1,
      takeoverRefusal: 'conflicting_writer',
    );
    extension = ProjectCollaborationExtension.mount(
      composition: composition,
      owner: owner,
    );
    extension.source.seed(
      GraphResourceValue.fromJson(threeProjectDocumentJson()),
    );
    extension
      ..start()
      ..publishEpoch();
    await pumpExtension(tester, extension);
    await until(tester, () => extension.session.current != null);
    final receipt = await extension.session.actions.request(
      actionRef: ProjectCollaborationActions.takeover,
      nodeId: 'licoup.node/alpha-review',
    );
    expect(receipt.accepted, isFalse);
    expect(receipt.code, 'conflicting_writer');
    expect(receipt.nodeId, 'licoup.node/alpha-review');
    expect(owner.performed.last, ProjectCollaborationActions.takeover);
    await drainWorkers(tester, composition, runtime);
  });

  testWidgets('an insertion commits only at the previewed revision', (
    tester,
  ) async {
    final runtime = PresentationRuntime();
    addTearDown(runtime.dispose);
    final composition = ExtensionUiComposition(runtime: runtime);
    addTearDown(composition.dispose);
    late final ProjectCollaborationExtension extension;
    final owner = SyntheticProjectCollaborationOwner(
      currentRevision: () =>
          extension.source.snapshot?.value.document.planRevision ?? 0,
    );
    extension = ProjectCollaborationExtension.mount(
      composition: composition,
      owner: owner,
    );
    extension.source.seed(
      GraphResourceValue.fromJson(threeProjectDocumentJson()),
    );
    extension
      ..start()
      ..publishEpoch();
    await pumpExtension(tester, extension);
    await until(tester, () => extension.session.current != null);

    final preview = await extension.session.previewInsert(
      unitRef: 'unit/alpha-extra',
      laneId: 'licoup.lane/build',
      role: 'licoup.role/builder',
    );
    expect(preview, isNotNull);
    expect(preview!.affectedNodeIds, isNotEmpty);
    final accepted = await extension.session.commitInsert();
    expect(accepted.accepted, isTrue);
    expect(owner.commitCount, 1);

    final second = await extension.session.commitInsert();
    expect(second.accepted, isFalse);
    expect(second.code, 'no_preview');
    expect(owner.commitCount, 1, reason: 'a preview commits exactly once');
    await drainWorkers(tester, composition, runtime);
  });

  testWidgets('a commit citing a stale plan revision is refused by the port', (
    tester,
  ) async {
    final runtime = PresentationRuntime();
    addTearDown(runtime.dispose);
    final composition = ExtensionUiComposition(runtime: runtime);
    addTearDown(composition.dispose);
    late final ProjectCollaborationExtension extension;
    final owner = SyntheticProjectCollaborationOwner(
      currentRevision: () =>
          extension.source.snapshot?.value.document.planRevision ?? 0,
    );
    extension = ProjectCollaborationExtension.mount(
      composition: composition,
      owner: owner,
    );
    extension.source.seed(
      GraphResourceValue.fromJson(threeProjectDocumentJson()),
    );
    extension
      ..start()
      ..publishEpoch();
    await pumpExtension(tester, extension);
    await until(tester, () => extension.session.current != null);
    final preview = await extension.session.previewInsert(
      unitRef: 'unit/alpha-extra',
      laneId: 'licoup.lane/build',
      role: 'licoup.role/builder',
    );
    expect(preview, isNotNull);
    // A newer plan revision lands before the commit.
    extension.source.publish(
      GraphResourceValue.fromJson(threeProjectDocumentJson(planRevision: 2)),
      changedNodeIds: <String>{'licoup.node/alpha-build'},
    );
    await until(tester, () => extension.session.current?.planRevision == 2);
    final receipt = await extension.session.actions.request(
      actionRef: ProjectCollaborationActions.insertCommit,
      revision: preview!.revision,
      values: <String, String>{'previewRef': preview.previewRef},
    );
    expect(receipt.accepted, isFalse);
    expect(receipt.code, 'stale_revision');
    expect(owner.commitCount, 0, reason: 'the owner never saw a stale commit');
    await drainWorkers(tester, composition, runtime);
  });

  testWidgets('pause stays waiting until the native receipt arrives', (
    tester,
  ) async {
    final runtime = PresentationRuntime();
    addTearDown(runtime.dispose);
    final composition = ExtensionUiComposition(runtime: runtime);
    addTearDown(composition.dispose);
    late final ProjectCollaborationExtension extension;
    final gate = Completer<void>();
    final owner = _GatedOwner(
      currentRevision: () =>
          extension.source.snapshot?.value.document.planRevision ?? 0,
      gate: gate,
    );
    extension = ProjectCollaborationExtension.mount(
      composition: composition,
      owner: owner,
    );
    extension.source.seed(
      GraphResourceValue.fromJson(threeProjectDocumentJson()),
    );
    extension
      ..start()
      ..publishEpoch();
    await pumpExtension(tester, extension);
    await until(tester, () => extension.session.current != null);

    final pending = extension.session.actions.request(
      actionRef: ProjectCollaborationActions.pause,
      nodeId: 'licoup.node/alpha-build',
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      extension.session.actions.receipts,
      isEmpty,
      reason: 'no receipt yet, so nothing is shown as paused',
    );
    expect(
      extension
          .session
          .current!
          .statusById['licoup.node/alpha-build']!
          .execution,
      GraphExecutionState.running,
      reason: 'the projected state still says running',
    );
    gate.complete();
    final receipt = await pending;
    expect(receipt.accepted, isTrue);
    expect(receipt.actionRef, ProjectCollaborationActions.pause);
    await drainWorkers(tester, composition, runtime);
  });
}

/// An owner whose pause answer waits for a test-controlled gate.
final class _GatedOwner implements ProjectCollaborationActionOwner {
  _GatedOwner({required this.currentRevision, required this.gate});

  final int Function() currentRevision;
  final Completer<void> gate;

  @override
  Future<ProjectCollaborationReceipt> perform(
    ProjectCollaborationActionRequest request,
  ) async {
    await gate.future;
    return ProjectCollaborationReceipt(
      actionRef: request.actionRef,
      accepted: true,
      code: 'accepted',
      revision: currentRevision(),
      nodeId: request.nodeId,
    );
  }
}
