import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/contracts/collaboration_run_models.dart';
import 'package:licoup/src/frontend/features/collaboration/ui/collaboration_flowchart_view.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/collaboration/collaboration_binding.dart';
import 'package:licoup/src/projections/collaboration/collaboration_presentation_source.dart';

import 'support/collaboration_fixture.dart';

final class _Harness {
  _Harness(this.port, this.source, this.binding);

  final FakeCollaborationRunPort port;
  final CollaborationPresentationSource source;
  final CollaborationBinding binding;
}

Future<_Harness> _pumpView(
  WidgetTester tester, {
  Locale locale = const Locale('zh'),
  String presetId = AppearancePresetIds.starlitGold,
  Brightness brightness = Brightness.dark,
  bool disableAnimations = true,
  Size surfaceSize = const Size(1440, 900),
}) async {
  final port = FakeCollaborationRunPort();
  final source = CollaborationPresentationSource(
    port: port,
    conversationId: 'conv-1',
  );
  final binding = CollaborationBinding(
    projection: source,
    intents: source,
    effects: source,
  );
  await tester.binding.setSurfaceSize(surfaceSize);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  addTearDown(source.dispose);
  addTearDown(port.close);
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      supportedLocales: LicoStrings.supportedLocales,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      theme: buildLicoTheme(presetId: presetId, platformBrightness: brightness),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(disableAnimations: disableAnimations),
        child: child!,
      ),
      home: Scaffold(body: CollaborationFlowchartView(binding: binding)),
    ),
  );
  return _Harness(port, source, binding);
}

void main() {
  Future<_Harness> pump(
    WidgetTester tester, {
    CollaborationRunSnapshot? snapshot,
    Locale locale = const Locale('zh'),
    bool disableAnimations = true,
  }) async {
    final harness = await _pumpView(
      tester,
      locale: locale,
      disableAnimations: disableAnimations,
    );
    if (snapshot != null) {
      harness.port.emit(snapshot);
      await tester.pump();
      await tester.pump();
    }
    return harness;
  }

  testWidgets('task cards render their live status and actions', (
    tester,
  ) async {
    final states = <String, CollaborationNodeState>{
      ...collabStatesV2(),
      'idx': collabState(CollaborationNodeStatus.waitingUser),
      'ui': collabState(CollaborationNodeStatus.succeeded, artifactCount: 2),
      'bench': collabState(CollaborationNodeStatus.running, startedRevision: 2),
      'arch': collabState(CollaborationNodeStatus.heldForPlan),
    };
    await pump(tester, snapshot: collabSnapshotV2(nodeStates: states));
    expect(find.text('待你决定'), findsWidgets);
    expect(find.text('已完成'), findsWidgets);
    expect(find.text('进行中'), findsWidgets);
    // A held node keeps its label out of the live status row.
    expect(find.text('待计划审批'), findsWidgets);
    expect(find.text('2 个产物'), findsWidgets);
    expect(find.text('查看进展'), findsWidgets);
  });

  testWidgets('gate decision buttons dispatch DecideCollaborationGate', (
    tester,
  ) async {
    final harness = await pump(tester, snapshot: collabSnapshotV2());
    // Fit the graph so the Index card is a hit-testable size.
    await tester.tap(find.byTooltip('适应'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('collab-card-idx')));
    await tester.pump();
    expect(find.byKey(const Key('collab-popover')), findsOneWidget);
    expect(find.textContaining('Lead 无法判断 · 等待你的决定'), findsOneWidget);
    await tester.tap(find.text('仅索引 50MB 以下'));
    await tester.pump();
    expect(harness.port.sent, hasLength(1));
    final command = harness.port.sent.single;
    expect(command, isA<DecideGate>());
    expect(command.expectedHead, 2);
    expect((command as DecideGate).gateId, 'gate-idx');
    expect(command.optionId, 'small');
    expect(find.byKey(const Key('collab-popover')), findsNothing);
  });

  testWidgets('proposal banner actions dispatch the right intents', (
    tester,
  ) async {
    final harness = await pump(tester, snapshot: collabSnapshotWithProposal());
    expect(find.byKey(const Key('collab-banner-proposal')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('collab-banner-proposal')),
        matching: find.textContaining('Lead 提议更新计划'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('同意'));
    await tester.pump();
    expect(harness.port.sent.last, isA<ApproveProposal>());
    expect(harness.port.sent.last.expectedHead, 1);

    await tester.tap(find.text('拒绝'));
    await tester.pump();
    expect(harness.port.sent.last, isA<RejectProposal>());

    await tester.tap(find.text('让 Lead 修改'));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('collab-revise-field')),
      '加一个验证步骤',
    );
    await tester.tap(find.text('发送'));
    await tester.pump();
    final request = harness.port.sent.last;
    expect(request, isA<RequestRevision>());
    expect((request as RequestRevision).note, '加一个验证步骤');
  });

  testWidgets('the history drawer lists newest first and revert dispatches', (
    tester,
  ) async {
    final snapshot = CollaborationRunSnapshot(
      runId: 'run-1',
      conversationId: 'conv-1',
      status: CollaborationRunStatus.completed,
      startedAt: 1759300000000,
      updatedAt: 1759300180000,
      planChangePolicy: CollaborationPlanChangePolicy.ask,
      gateReviewPolicy: CollaborationGateReviewPolicy.assistant,
      headNumber: 3,
      revisions: [collabRevisionV1(), collabRevisionV2(), collabRevisionV3()],
      graph: collaborationGraphV1(),
      nodeStates: collabStatesV1Active(),
    );
    final harness = await pump(tester, snapshot: snapshot);
    await tester.tap(find.byKey(const Key('collab-revision-chip')));
    await tester.pumpAndSettle();
    expect(find.text('计划历史'), findsOneWidget);

    final v3 = tester.getTopLeft(find.text('v3'));
    final v2 = tester.getTopLeft(find.text('v2'));
    final v1 = tester.getTopLeft(find.text('v1'));
    expect(v3.dy, lessThan(v2.dy));
    expect(v2.dy, lessThan(v1.dy));
    expect(find.text('自动同意'), findsWidgets);
    expect(find.text('你已同意'), findsWidgets);

    await tester.tap(find.text('撤销此变更').last);
    await tester.pump();
    expect(harness.port.sent.last, isA<RevertTo>());
    expect((harness.port.sent.last as RevertTo).number, 1);
  });

  testWidgets('the diff toggle reveals change tags', (tester) async {
    await pump(tester, snapshot: collabSnapshotV2());
    expect(find.text('已调整'), findsNothing);
    expect(find.textContaining('改派'), findsNothing);
    await tester.tap(find.byKey(const Key('collab-toggle-diff')));
    await tester.pump();
    expect(find.text('已调整'), findsWidgets);
    expect(find.textContaining('改派'), findsWidgets);
    expect(find.text('+ 新增'), findsWidgets);
  });

  testWidgets('the historical banner restores the viewed revision', (
    tester,
  ) async {
    final snapshot = CollaborationRunSnapshot(
      runId: 'run-1',
      conversationId: 'conv-1',
      status: CollaborationRunStatus.completed,
      startedAt: 1759300000000,
      updatedAt: 1759300180000,
      planChangePolicy: CollaborationPlanChangePolicy.ask,
      gateReviewPolicy: CollaborationGateReviewPolicy.assistant,
      headNumber: 3,
      revisions: [collabRevisionV1(), collabRevisionV2(), collabRevisionV3()],
      graph: collaborationGraphV1(),
      nodeStates: collabStatesV1Active(),
    );
    final harness = await pump(tester, snapshot: snapshot);
    harness.port.revisionGraphs[2] = collaborationGraphV2();
    await tester.tap(find.byKey(const Key('collab-revision-chip')));
    await tester.pumpAndSettle();
    // Select v2: the view switches to a structure-only historical revision.
    await tester.tap(find.text('v2'));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('collab-banner-historical')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('collab-banner-historical')),
        matching: find.textContaining('正在查看 v2'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('恢复此版本'));
    await tester.pump();
    expect(harness.port.sent.last, isA<RevertTo>());
    expect((harness.port.sent.last as RevertTo).number, 2);

    // Back to latest is a local projection switch, not a command.
    final sent = harness.port.sent.length;
    await tester.tap(find.text('回到最新'));
    await tester.pump();
    await tester.pump();
    expect(harness.port.sent, hasLength(sent));
    expect(find.byKey(const Key('collab-banner-historical')), findsNothing);
  });

  testWidgets('Escape closes the popover and returns focus to the card', (
    tester,
  ) async {
    await pump(tester, snapshot: collabSnapshotV2());
    await tester.tap(find.byTooltip('适应'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('collab-card-idx')));
    await tester.pump();
    expect(find.byKey(const Key('collab-popover')), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(const Key('collab-popover')), findsNothing);
    final cardFocus = tester.widget<Focus>(
      find
          .descendant(
            of: find.byKey(const Key('collab-card-idx')),
            matching: find.byType(Focus),
          )
          .first,
    );
    expect(cardFocus.focusNode?.hasFocus, isTrue);
  });

  testWidgets('reduced motion leaves no ticker running after settling', (
    tester,
  ) async {
    await pump(tester, snapshot: collabSnapshotV2(), disableAnimations: true);
    await tester.pumpAndSettle();
    expect(tester.binding.transientCallbackCount, 0);
  });
}
