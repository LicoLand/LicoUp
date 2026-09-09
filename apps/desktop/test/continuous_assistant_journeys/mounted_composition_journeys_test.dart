import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/frontend/features/continuous_assistant/continuous_assistant.dart';

import 'support/journey_bridge.dart';
import 'support/journey_host.dart';
import 'support/journey_oracle.dart';

void main() {
  setUp(JourneyOracle.reset);

  testWidgets(
    'REQ-04-007 AC-04-004 A/B cards stay after original messages when B completes first',
    (tester) async {
      final session = JourneySession();
      await session.start();
      await session.select(parentId);
      await session.mount(tester);
      await session.settle(tester);
      await revealCard(tester, goalAId);
      await revealCard(tester, goalBId);

      expect(find.text('ordinary before A'), findsOneWidget);
      expect(find.text('ordinary between A and B'), findsOneWidget);
      expect(find.text('ordinary after B'), findsOneWidget);
      expect(find.byKey(ContinuousAssistantKeys.card(goalAId)), findsOneWidget);
      expect(find.byKey(ContinuousAssistantKeys.card(goalBId)), findsOneWidget);
      _expectCardOrder(tester);
      expect(
        tester
            .widget<Text>(find.byKey(ContinuousAssistantKeys.sequence(goalAId)))
            .data,
        '$cardASequence',
      );
      expect(
        tester
            .widget<Text>(find.byKey(ContinuousAssistantKeys.sequence(goalBId)))
            .data,
        '$cardBSequence',
      );
      expect(find.text('review-on-reply'), findsOneWidget);
      expect(
        find.byKey(ContinuousAssistantKeys.child(childAId)),
        findsOneWidget,
      );
      expect(
        find.byKey(ContinuousAssistantKeys.child(childBId)),
        findsOneWidget,
      );

      session.bridge.completeGoal(goalBId);
      await session.owner.reloadSelected();
      await session.settle(tester);
      _expectCardOrder(tester);
      expect(
        tester
            .widget<Text>(
              find.byKey(ContinuousAssistantKeys.lifecycle(goalBId)),
            )
            .data,
        'achieved',
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(ContinuousAssistantKeys.lifecycle(goalAId)),
            )
            .data,
        'active',
      );
      expect(
        session.owner.events
            .singleWhere((event) => event.id == cardAEventId)
            .sequence,
        cardASequence,
      );
      expect(
        session.owner.events
            .singleWhere((event) => event.id == cardBEventId)
            .sequence,
        cardBSequence,
      );

      session.bridge.completeGoal(goalAId);
      await session.owner.reloadSelected();
      await session.settle(tester);
      _expectCardOrder(tester);
      expect(
        tester
            .widget<Text>(
              find.byKey(ContinuousAssistantKeys.lifecycle(goalAId)),
            )
            .data,
        'achieved',
      );
      _assertNoModeCeremony();
      _assertZeroForcedBurden(session.bridge);
      await session.close(tester);
    },
  );

  testWidgets(
    'child addendum authors are real human worker reviewer memberships',
    (tester) async {
      final session = JourneySession();
      await session.start();
      await session.select(parentId);
      await session.mount(tester);
      await session.settle(tester);
      await tapOpenCard(tester, goalAId);
      await session.settle(tester);
      expect(paneOf(tester).canonical.conversationId, childAId);
      expect(paneOf(tester).canonical.conversation?.id, childAId);
      expect(find.text('delegate notes A'), findsOneWidget);
      expect(find.text('worker A $sentinelA'), findsOneWidget);
      expect(find.text('reviewer A accepted'), findsOneWidget);
      expect(find.text('Worker A'), findsWidgets);
      expect(find.text('Reviewer A'), findsWidgets);
      expect(find.text('worker A $sentinelA'), findsOneWidget);

      await tester.tap(find.byKey(ContinuousAssistantKeys.child(childBId)));
      await session.settle(tester);
      expect(paneOf(tester).canonical.conversationId, childBId);
      await reveal(tester, find.text('discuss B'));
      expect(find.text('discuss B'), findsOneWidget);
      expect(find.text('Worker B'), findsWidgets);
      expect(find.text('Reviewer B'), findsWidgets);
      expect(find.text('worker A $sentinelA'), findsNothing);
      expect(find.textContaining(sentinelA), findsNothing);
      _assertZeroForcedBurden(session.bridge);
      await session.close(tester);
    },
  );

  testWidgets(
    'retry review reopen and history keep the same child identities',
    (tester) async {
      final bridge = JourneyBridge();
      final session = JourneySession(bridge: bridge);
      await session.start();
      await session.select(parentId);
      await session.mount(tester);
      await session.settle(tester);

      await tester.tap(find.byKey(ContinuousAssistantKeys.child(childAId)));
      await session.settle(tester);
      expect(paneOf(tester).canonical.conversationId, childAId);

      await tester.tap(sidebarText('Parent'));
      await session.settle(tester);
      expect(paneOf(tester).canonical.conversationId, parentId);
      await expandCard(tester, goalAId);
      await tapKey(tester, ContinuousAssistantKeys.pause(goalAId));
      await session.settle(tester);
      expect(
        tester
            .widget<Text>(find.byKey(ContinuousAssistantKeys.control(goalAId)))
            .data,
        'paused',
      );
      await tapKey(tester, ContinuousAssistantKeys.resume(goalAId));
      await session.settle(tester);
      expect(
        tester
            .widget<Text>(find.byKey(ContinuousAssistantKeys.control(goalAId)))
            .data,
        'enabled',
      );
      await tapOpenCard(tester, goalAId);
      await session.settle(tester);
      expect(paneOf(tester).canonical.conversationId, childAId);
      expect(find.text('worker A $sentinelA'), findsOneWidget);

      await tester.tap(sidebarText('Parent'));
      await session.settle(tester);
      await tester.tap(find.byKey(ContinuousAssistantKeys.child(childBId)));
      await session.settle(tester);
      expect(paneOf(tester).canonical.conversationId, childBId);
      expect(find.text('review-on-reply'), findsNothing);
      await reveal(tester, find.text('discuss B'));
      expect(find.text('discuss B'), findsOneWidget);

      await session.close(tester);
      final restored = JourneySession(bridge: bridge);
      await restored.start();
      await restored.select(parentId);
      await restored.mount(tester);
      await restored.settle(tester);
      expect(
        find.byKey(ContinuousAssistantKeys.child(childAId)),
        findsOneWidget,
      );
      expect(
        find.byKey(ContinuousAssistantKeys.child(childBId)),
        findsOneWidget,
      );
      await tapOpenCard(tester, goalAId);
      await restored.settle(tester);
      expect(paneOf(tester).canonical.conversationId, childAId);
      expect(find.text('reviewer A accepted'), findsOneWidget);
      _assertZeroForcedBurden(restored.bridge);
      await restored.close(tester);
    },
  );

  testWidgets(
    'REQ-04-008 A completion while typing scrolled in B keeps focus draft viewport',
    (tester) async {
      final session = JourneySession();
      await session.start();
      await session.select(childBId);
      await session.mount(tester);
      await session.settle(tester);
      expect(paneOf(tester).canonical.conversationId, childBId);

      final composer = composerField();
      await tester.tap(composer);
      await tester.enterText(composer, draftInB);
      await tester.pump();
      expect(tester.widget<TextField>(composer).controller?.text, draftInB);
      expect(tester.widget<TextField>(composer).focusNode?.hasFocus, isTrue);

      final scrollable = messageScrollable();
      expect(scrollable, findsOneWidget);
      final position = tester.state<ScrollableState>(scrollable).position;
      final scrolledOffset = position.pixels + 240;
      position.jumpTo(scrolledOffset);
      await tester.pump();
      final beforeOffset = tester
          .state<ScrollableState>(scrollable)
          .position
          .pixels;

      session.bridge.completeGoal(goalAId);
      session.bridge.requests.clear();
      await session.deliverPendingNotices(tester);

      expect(paneOf(tester).canonical.conversationId, childBId);
      expect(tester.widget<TextField>(composer).controller?.text, draftInB);
      expect(tester.widget<TextField>(composer).focusNode?.hasFocus, isTrue);
      expect(
        tester.state<ScrollableState>(scrollable).position.pixels,
        beforeOffset,
      );
      expect(find.text('Task completed'), findsOneWidget);
      expect(
        session.bridge.requests.where(
          (request) => request['action'] == 'conversation.get',
        ),
        isEmpty,
      );
      _assertZeroForcedBurden(session.bridge);
      await session.close(tester);
    },
  );

  testWidgets(
    'REQ-04-008 explicit toast opens current child pane; denied resolve stays on B',
    (tester) async {
      final denied = JourneySession();
      await denied.start();
      await denied.select(childBId);
      denied.owner.updateDraft(draftInB);
      denied.bridge.failResolve = true;
      await denied.mount(tester);
      await denied.settle(tester);
      denied.bridge.completeGoal(goalAId);
      denied.bridge.requests.clear();
      await denied.deliverPendingNotices(tester);
      expect(find.text('Open original matter'), findsOneWidget);
      await tester.tap(find.text('Open original matter'));
      await denied.settle(tester);
      expect(paneOf(tester).canonical.conversationId, childBId);
      expect(denied.owner.selectedConversationId, childBId);
      await denied.close(tester);

      final allowed = JourneySession();
      await allowed.start();
      await allowed.select(childBId);
      await allowed.mount(tester);
      await allowed.settle(tester);
      allowed.bridge.completeGoal(goalAId);
      await allowed.deliverPendingNotices(tester);
      await tester.tap(find.text('Open original matter'));
      await allowed.settle(tester);
      expect(paneOf(tester).canonical.conversationId, childAId);
      expect(paneOf(tester).canonical.conversation?.id, childAId);
      expect(find.text('worker A $sentinelA'), findsOneWidget);
      expect(find.text('delegate notes A'), findsOneWidget);
      _assertZeroForcedBurden(allowed.bridge);
      await allowed.close(tester);
    },
  );

  testWidgets(
    'REQ-04-008 keyboard semantics narrow long message and pending approval stay usable',
    (tester) async {
      final session = JourneySession();
      await session.start();
      await session.select(parentId);
      await session.mount(tester);
      await session.settle(tester);
      await expandCard(tester, goalAId);
      await reveal(tester, find.byKey(ContinuousAssistantKeys.pause(goalAId)));
      final composer = composerField();
      await tester.tap(composer);
      await tester.pump();
      expect(tester.widget<TextField>(composer).focusNode?.hasFocus, isTrue);
      await traverseToCommand(tester, ContinuousAssistantKeys.pause(goalAId));
      expect(
        commandButtonFocused(tester, ContinuousAssistantKeys.pause(goalAId)),
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await session.settle(tester);
      expect(
        session.bridge.requests.where(
          (request) => request['action'] == 'pause-goal',
        ),
        isNotEmpty,
      );
      expect(
        tester
            .widget<Text>(find.byKey(ContinuousAssistantKeys.control(goalAId)))
            .data,
        'paused',
      );

      final semantics = tester.ensureSemantics();
      try {
        expect(
          tester.getSemantics(
            find.byKey(ContinuousAssistantKeys.expand(goalAId)),
          ),
          isSemantics(isButton: true),
        );
        expect(
          tester
              .getSemantics(find.byKey(ContinuousAssistantKeys.card(goalAId)))
              .label,
          contains('Matter card goal:a, status active, anchor 2'),
        );
        expect(
          tester.getSemantics(
            find.byKey(ContinuousAssistantKeys.child(childAId)),
          ),
          isSemantics(isButton: true),
        );
      } finally {
        semantics.dispose();
      }
      expect(find.text('review-on-reply'), findsOneWidget);

      await session.close(tester);
      final narrow = JourneySession();
      await narrow.start();
      await narrow.select(parentId);
      var overflowed = false;
      final previousOnError = FlutterError.onError;
      FlutterError.onError = (details) {
        if (details.toString().contains('overflowed')) {
          overflowed = true;
          return;
        }
        previousOnError?.call(details);
      };
      try {
        await narrow.mount(tester, size: const Size(280, 720));
        await narrow.settle(tester);
        expect(find.text('ordinary before A'), findsOneWidget);
        expect(
          find.byKey(ContinuousAssistantKeys.card(goalAId)),
          findsOneWidget,
        );
        await tester.tap(find.byKey(ContinuousAssistantKeys.child(childBId)));
        await narrow.settle(tester);
        expect(find.text('B line 22'), findsWidgets);
      } finally {
        FlutterError.onError = previousOnError;
      }
      expect(
        overflowed,
        isFalse,
        reason:
            'narrow 280x720 overflowed the mounted sidebar/pane/card composition',
      );
      _assertZeroForcedBurden(narrow.bridge);
      await narrow.close(tester);
    },
  );

  testWidgets(
    'natural correct pause resume emit dispatched actions and visible state',
    (tester) async {
      final session = JourneySession();
      await session.start();
      await session.select(parentId);
      await session.mount(tester);
      await session.settle(tester);
      session.bridge.requests.clear();

      await expandCard(tester, goalAId);
      await tapKey(tester, ContinuousAssistantKeys.correct(goalAId));
      await session.settle(tester);
      await tapKey(tester, ContinuousAssistantKeys.pause(goalAId));
      await session.settle(tester);
      expect(
        tester
            .widget<Text>(find.byKey(ContinuousAssistantKeys.control(goalAId)))
            .data,
        'paused',
      );
      expect(
        find.byKey(ContinuousAssistantKeys.resume(goalAId)),
        findsOneWidget,
      );
      await tapKey(tester, ContinuousAssistantKeys.resume(goalAId));
      await session.settle(tester);
      expect(
        tester
            .widget<Text>(find.byKey(ContinuousAssistantKeys.control(goalAId)))
            .data,
        'enabled',
      );

      final actions = session.bridge.requests
          .map((request) => request['action']?.toString())
          .whereType<String>()
          .toList();
      expect(actions, contains('correct-association'));
      expect(actions, contains('pause-goal'));
      expect(actions, contains('resume-goal'));
      expect(
        session.bridge.requests.where(
          (request) =>
              request['action'] == 'pause-goal' &&
              request['goalId'] == goalAId &&
              request['conversationId'] == parentId,
        ),
        hasLength(1),
      );
      expect(actions.contains('conversation.create'), isFalse);
      _assertZeroForcedBurden(session.bridge);
      await session.close(tester);
    },
  );

  testWidgets(
    'REQ-04-007 AC-04-004 composer posts unrelated B then scoped continue A',
    (tester) async {
      final session = JourneySession();
      await session.start();
      await session.select(parentId);
      await session.mount(tester);
      await session.settle(tester);
      session.bridge.requests.clear();
      session.bridge.associations.clear();

      await submitComposer(tester, session, askUnrelatedB);
      await submitComposer(tester, session, scopedContinueA);

      expect(JourneyOracle.postedMessageCount(session.bridge), 2);
      expect(JourneyOracle.afterPostCount(session.bridge), 2);
      expect(JourneyOracle.postedContents(session.bridge), [
        askUnrelatedB,
        scopedContinueA,
      ]);
      expect(
        session.bridge.requests.where(
          (request) =>
              request['action'] == 'conversation.message.post' &&
              request['conversationId'] == parentId &&
              request['authorMembershipId'] == ownerMembershipId,
        ),
        hasLength(2),
      );
      final associations = JourneyOracle.postedAssociations(session.bridge);
      expect(associations, hasLength(2));
      expect(associations[0]['goalId'], goalBId);
      expect(associations[0]['conversationId'], parentId);
      expect(associations[1]['goalId'], goalAId);
      expect(associations[1]['conversationId'], parentId);
      expect(find.text(askUnrelatedB), findsOneWidget);
      expect(find.text(scopedContinueA), findsWidgets);
      expect(find.text('ordinary before A'), findsOneWidget);
      await revealCard(tester, goalAId);
      await revealCard(tester, goalBId);
      _expectCardOrder(tester);
      expect(
        session.owner.events
            .singleWhere((event) => event.id == cardAEventId)
            .id,
        cardAEventId,
      );
      expect(
        session.owner.events
            .singleWhere((event) => event.id == cardAEventId)
            .sequence,
        cardASequence,
      );
      expect(
        session.owner.events
            .singleWhere((event) => event.id == cardAEventId)
            .parts
            .single
            .id,
        'part:$cardAEventId',
      );

      await tapOpenCard(tester, goalAId);
      await session.settle(tester);
      expect(paneOf(tester).canonical.conversationId, childAId);
      expect(find.text(scopedContinueA), findsOneWidget);
      expect(find.text(askUnrelatedB), findsNothing);
      expect(find.text('worker A $sentinelA'), findsOneWidget);

      await tester.tap(sidebarText('Parent'));
      await session.settle(tester);
      session.bridge.completeGoal(goalBId);
      await session.owner.reloadSelected();
      await session.settle(tester);
      session.bridge.completeGoal(goalAId);
      await session.owner.reloadSelected();
      await session.settle(tester);
      _expectCardOrder(tester);
      expect(find.byKey(ContinuousAssistantKeys.card(goalAId)), findsOneWidget);
      expect(find.byKey(ContinuousAssistantKeys.card(goalBId)), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(ContinuousAssistantKeys.sequence(goalAId)))
            .data,
        '$cardASequence',
      );
      expect(
        tester
            .widget<Text>(find.byKey(ContinuousAssistantKeys.sequence(goalBId)))
            .data,
        '$cardBSequence',
      );
      _assertNoModeCeremony();
      expect(JourneyOracle.postedMessageCount(session.bridge), 2);
      _assertZeroForcedBurden(session.bridge);
      await session.close(tester);
    },
  );

  testWidgets(
    'REQ-04-007 AC-04-004 posted A/B admission keeps anchors after B then A',
    (tester) async {
      final session = JourneySession(bridge: JourneyBridge.admission());
      await session.start();
      await session.select(parentId);
      await session.mount(tester);
      await session.settle(tester);
      expect(find.byKey(ContinuousAssistantKeys.card(goalAId)), findsNothing);
      expect(find.byKey(ContinuousAssistantKeys.card(goalBId)), findsNothing);

      await submitComposer(tester, session, postedOrdinaryBeforeA);
      await submitComposer(tester, session, startLongWorkA);
      await submitComposer(tester, session, postedOrdinaryBetween);
      await submitComposer(tester, session, askUnrelatedB);
      await submitComposer(tester, session, postedOrdinaryAfterB);

      expect(JourneyOracle.postedMessageCount(session.bridge), 5);
      expect(JourneyOracle.afterPostCount(session.bridge), 5);
      expect(find.text(postedOrdinaryBeforeA), findsOneWidget);
      expect(find.text(postedOrdinaryBetween), findsOneWidget);
      expect(find.text(postedOrdinaryAfterB), findsOneWidget);
      expect(find.byKey(ContinuousAssistantKeys.card(goalAId)), findsOneWidget);
      expect(find.byKey(ContinuousAssistantKeys.card(goalBId)), findsOneWidget);
      await revealCard(tester, goalAId);
      await revealCard(tester, goalBId);
      _expectPostedCardOrder(tester);
      final cardA = session.owner.events.singleWhere(
        (event) => event.id == session.bridge.goalEventId(goalAId),
      );
      final cardB = session.owner.events.singleWhere(
        (event) => event.id == session.bridge.goalEventId(goalBId),
      );
      expect(cardA.sequence, 2);
      expect(cardB.sequence, 4);
      expect(cardA.parts.single.id, session.bridge.goalCardPartId(goalAId));
      expect(cardB.parts.single.id, session.bridge.goalCardPartId(goalBId));
      expect(
        session.owner.events.where(
          (event) => event.id == session.bridge.goalEventId(goalAId),
        ),
        hasLength(1),
      );
      expect(
        session.owner.events.where(
          (event) => event.id == session.bridge.goalEventId(goalBId),
        ),
        hasLength(1),
      );

      session.bridge.completeGoal(goalBId);
      await session.owner.reloadSelected();
      await session.settle(tester);
      session.bridge.completeGoal(goalAId);
      await session.owner.reloadSelected();
      await session.settle(tester);
      _expectPostedCardOrder(tester);
      expect(find.byKey(ContinuousAssistantKeys.card(goalAId)), findsOneWidget);
      expect(find.byKey(ContinuousAssistantKeys.card(goalBId)), findsOneWidget);
      expect(
        session.owner.events
            .singleWhere(
              (event) => event.id == session.bridge.goalEventId(goalAId),
            )
            .sequence,
        2,
      );
      expect(
        session.owner.events
            .singleWhere(
              (event) => event.id == session.bridge.goalEventId(goalBId),
            )
            .sequence,
        4,
      );
      expect(
        session.owner.events.where(
          (event) => event.id == session.bridge.goalEventId(goalAId),
        ),
        hasLength(1),
      );
      expect(
        session.owner.events.where(
          (event) => event.id == session.bridge.goalEventId(goalBId),
        ),
        hasLength(1),
      );
      _assertNoModeCeremony();
      _assertZeroForcedBurden(session.bridge);
      await session.close(tester);
    },
  );

  testWidgets(
    'retry attempt reviewer update and history keep the same child card',
    (tester) async {
      final bridge = JourneyBridge()..failNextAfterPost = 1;
      final session = JourneySession(bridge: bridge);
      await session.start();
      await session.select(parentId);
      await session.mount(tester);
      await session.settle(tester);
      await _expectStableCardA(session, tester);

      await tester.tap(find.byKey(ContinuousAssistantKeys.child(childAId)));
      await session.settle(tester);
      expect(paneOf(tester).canonical.conversationId, childAId);
      await _expectChildAAuthors(tester, session, extraTexts: const []);

      await submitComposer(tester, session, retryAttemptA);
      final failedEventId = 'event:$childAId:4';
      await reveal(tester, find.text(retryAttemptA));
      await waitUntil(
        tester,
        () => retryAction(failedEventId).evaluate().isNotEmpty,
        because: 'failed composer post did not expose the retry action',
      );
      expect(find.text(retryAttemptA), findsOneWidget);
      await _expectChildAAuthors(
        tester,
        session,
        extraTexts: const [retryAttemptA],
      );
      await _expectStableCardA(session, tester, selectedChild: true);

      await reveal(tester, retryAction(failedEventId));
      await tester.tap(retryAction(failedEventId));
      await waitUntil(
        tester,
        () =>
            JourneyOracle.countAction(
              session.bridge,
              'conversation.message.delete',
            ) ==
            1,
        because: 'retry did not post then delete the settled attempt',
      );
      await session.settle(tester);
      await reveal(tester, find.text(workerAttempt2A));
      expect(find.text(workerAttempt2A), findsOneWidget);
      expect(
        session.bridge.requests.where(
          (request) => request['action'] == 'conversation.message.post',
        ),
        hasLength(2),
      );
      expect(
        session.bridge.requests.where(
          (request) => request['action'] == 'conversation.dispatch.after-post',
        ),
        hasLength(2),
      );
      await _expectChildAAuthors(
        tester,
        session,
        extraTexts: [retryAttemptA, workerAttempt2A],
      );
      await tester.tap(sidebarText('Parent'));
      await session.settle(tester);
      await _expectStableCardA(session, tester);

      await tester.tap(find.byKey(ContinuousAssistantKeys.child(childAId)));
      await session.settle(tester);
      await submitComposer(tester, session, reviewUpdateA);
      expect(find.text(reviewerUpdatedA), findsOneWidget);
      await _expectChildAAuthors(
        tester,
        session,
        extraTexts: [
          retryAttemptA,
          workerAttempt2A,
          reviewUpdateA,
          reviewerUpdatedA,
        ],
      );
      await tester.tap(sidebarText('Parent'));
      await session.settle(tester);
      await _expectStableCardA(session, tester);

      await session.close(tester);
      final restored = JourneySession(bridge: bridge);
      await restored.start();
      await restored.select(parentId);
      await restored.mount(tester);
      await restored.settle(tester);
      await _expectStableCardA(restored, tester);
      await tapOpenCard(tester, goalAId);
      await restored.settle(tester);
      expect(paneOf(tester).canonical.conversationId, childAId);
      await _expectChildAAuthors(
        tester,
        restored,
        extraTexts: [
          retryAttemptA,
          workerAttempt2A,
          reviewUpdateA,
          reviewerUpdatedA,
        ],
      );
      _assertZeroForcedBurden(restored.bridge);
      await restored.close(tester);
    },
  );
}

void _expectCardOrder(WidgetTester tester) {
  expect(
    tester.getTopLeft(find.byKey(ContinuousAssistantKeys.card(goalAId))).dy,
    lessThan(
      tester.getTopLeft(find.byKey(ContinuousAssistantKeys.card(goalBId))).dy,
    ),
  );
  expect(
    tester.getTopLeft(find.text('ordinary before A')).dy,
    lessThan(
      tester.getTopLeft(find.byKey(ContinuousAssistantKeys.card(goalAId))).dy,
    ),
  );
  expect(
    tester.getTopLeft(find.byKey(ContinuousAssistantKeys.card(goalAId))).dy,
    lessThan(tester.getTopLeft(find.text('ordinary between A and B')).dy),
  );
  expect(
    tester.getTopLeft(find.text('ordinary between A and B')).dy,
    lessThan(
      tester.getTopLeft(find.byKey(ContinuousAssistantKeys.card(goalBId))).dy,
    ),
  );
}

void _assertNoModeCeremony() {
  expect(find.text('Goal'), findsNothing);
  expect(find.text('Code'), findsNothing);
  expect(find.text('Knowledge'), findsNothing);
  expect(find.text('New session'), findsNothing);
  expect(find.text('Submit task'), findsNothing);
  expect(find.text('任务模式'), findsNothing);
}

void _expectPostedCardOrder(WidgetTester tester) {
  expect(
    tester.getTopLeft(find.byKey(ContinuousAssistantKeys.card(goalAId))).dy,
    lessThan(
      tester.getTopLeft(find.byKey(ContinuousAssistantKeys.card(goalBId))).dy,
    ),
  );
  expect(
    tester.getTopLeft(find.text(postedOrdinaryBeforeA)).dy,
    lessThan(
      tester.getTopLeft(find.byKey(ContinuousAssistantKeys.card(goalAId))).dy,
    ),
  );
  expect(
    tester.getTopLeft(find.byKey(ContinuousAssistantKeys.card(goalAId))).dy,
    lessThan(tester.getTopLeft(find.text(postedOrdinaryBetween)).dy),
  );
  expect(
    tester.getTopLeft(find.text(postedOrdinaryBetween)).dy,
    lessThan(
      tester.getTopLeft(find.byKey(ContinuousAssistantKeys.card(goalBId))).dy,
    ),
  );
  expect(
    tester.getTopLeft(find.byKey(ContinuousAssistantKeys.card(goalBId))).dy,
    lessThan(tester.getTopLeft(find.text(postedOrdinaryAfterB)).dy),
  );
}

Future<void> _expectStableCardA(
  JourneySession session,
  WidgetTester tester, {
  bool selectedChild = false,
}) async {
  if (!selectedChild) {
    await revealCard(tester, goalAId);
    expect(find.byKey(ContinuousAssistantKeys.card(goalAId)), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(ContinuousAssistantKeys.sequence(goalAId)))
          .data,
      '$cardASequence',
    );
    final card = session.owner.events.singleWhere(
      (event) => event.id == cardAEventId,
    );
    expect(card.sequence, cardASequence);
    expect(card.parts.single.id, 'part:$cardAEventId');
  }
  expect(find.byKey(ContinuousAssistantKeys.child(childAId)), findsOneWidget);
}

Future<void> _expectChildAAuthors(
  WidgetTester tester,
  JourneySession session, {
  required List<String> extraTexts,
}) async {
  expect(paneOf(tester).canonical.conversationId, childAId);
  final memberships = session.owner.selectedConversation!.memberships
      .map((membership) => membership.id)
      .toSet();
  expect(
    memberships,
    containsAll(<String>[
      humanAMembershipId,
      workerAMembershipId,
      reviewerAMembershipId,
    ]),
  );
  expect(
    session.owner.selectedConversation!.memberships.map(
      (membership) => membership.principal.displayName,
    ),
    containsAll(<String>['You', 'Worker A', 'Reviewer A']),
  );
  final authors = session.owner.events
      .map((event) => event.authorMembershipId)
      .toSet();
  expect(
    authors,
    containsAll(<String>[
      humanAMembershipId,
      workerAMembershipId,
      reviewerAMembershipId,
    ]),
  );
  final texts = <String>[
    for (final event in session.owner.events)
      for (final part in event.parts)
        if (part.kind.wireName == 'text') part.content,
  ];
  expect(
    texts,
    containsAll(<String>[
      'delegate notes A',
      'worker A $sentinelA',
      'reviewer A accepted',
      ...extraTexts,
    ]),
  );
  for (final text in extraTexts) {
    await reveal(tester, find.text(text));
    expect(find.text(text), findsOneWidget);
  }
}

void _assertZeroForcedBurden(JourneyBridgeTrajectory trajectory) {
  expect(JourneyOracle.forcedCreateCount(trajectory), 0);
  expect(JourneyOracle.modeSwitchCount(trajectory), 0);
  expect(JourneyOracle.reExplanationCount(trajectory), 0);
}
