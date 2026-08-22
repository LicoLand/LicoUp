import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/features/agents/contracts/adaptive_flywheel_gateway.dart';
import 'package:licoup/src/application/features/agents/contracts/agent_conversation_gateway.dart';
import 'package:licoup/src/application/features/conversations/client_conversation_controller.dart';
import 'package:licoup/src/contracts/adaptive_flywheel_models.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/agent_dispatch_lane.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/conversations/canonical_group_conversation_pane.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_agents_strategy.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/shell/layout_palette_projection.dart';
import 'package:licoup/src/frontend/shared/ui/lico_activity_animations.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

void main() {
  testWidgets(
    'group strategy picker lists authorized revisions, starts on first send, and X does not cancel',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 640);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final callOrder = <String>[];
      final conversationRunner = _GroupConversationRunner(callOrder: callOrder);
      final gateway = _StrategyGateway(callOrder: callOrder);
      final openedRevisions = <String?>[];
      final controller = ClientConversationController(
        runner: conversationRunner,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.selectConversation('conversation:group');
      final targets = [
        _target('codex', 'Codex'),
        _target('worker-a', 'Worker A'),
        _target('claude-code', 'Claude Code'),
      ];

      await tester.pumpWidget(
        _groupApp(
          CanonicalGroupConversationPane(
            controller: controller,
            targets: targets,
            onCopyText: (_) async {},
            framed: false,
            flywheelGateway: gateway,
            onOpenAdaptiveFlywheel: (revision) async {
              openedRevisions.add(revision);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      final picker = find.byKey(const Key('canonical-group-strategy-picker'));
      expect(picker, findsOneWidget);
      expect(find.text('Your Assistant is ready'), findsOneWidget);
      expect(
        find.byKey(const Key('canonical-group-assistant-control')),
        findsOneWidget,
      );

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(picker));
      await tester.pump();
      expect(
        find.byKey(const Key('canonical-group-strategy-picker-panel')),
        findsOneWidget,
      );
      expect(find.text('Automatic adaptation'), findsOneWidget);
      expect(find.text('Authorized Graph'), findsOneWidget);
      expect(find.text('Pending Graph'), findsNothing);
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      final option = find.byKey(
        const Key('canonical-group-strategy-option-rev-auth'),
      );
      expect(tester.getSize(option).height, 32);
      expect(
        find.byKey(const Key('canonical-group-strategy-edit-rev-auth')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const Key('canonical-group-strategy-edit-rev-auth')),
      );
      await tester.pumpAndSettle();
      expect(openedRevisions, <String?>['rev-auth']);

      await mouse.moveTo(const Offset(1, 1));
      await tester.pump(const Duration(milliseconds: 220));
      await mouse.moveTo(tester.getCenter(picker));
      await tester.pump();

      await tester.tap(
        find.byKey(const Key('canonical-group-strategy-option-rev-auth')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Your Assistant is ready'), findsOneWidget);
      expect(
        find.byKey(const Key('canonical-group-assistant-control')),
        findsOneWidget,
      );
      expect(conversationRunner.strategyRevision, 'rev-auth');
      final membershipWritesBeforeRemount = conversationRunner.requests
          .where(
            (request) => request['action'] == 'conversation.membership.add',
          )
          .length;
      final strategyWritesBeforeRemount = conversationRunner.requests
          .where((request) => request['action'] == 'conversation.strategy.set')
          .length;

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.pumpWidget(
        _groupApp(
          CanonicalGroupConversationPane(
            controller: controller,
            targets: targets,
            onCopyText: (_) async {},
            framed: false,
            flywheelGateway: gateway,
            onOpenAdaptiveFlywheel: (revision) async {
              openedRevisions.add(revision);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Your Assistant is ready'), findsOneWidget);
      expect(
        find.byKey(const Key('canonical-group-assistant-control')),
        findsOneWidget,
      );
      expect(
        conversationRunner.requests
            .where(
              (request) => request['action'] == 'conversation.membership.add',
            )
            .length,
        membershipWritesBeforeRemount,
      );
      expect(
        conversationRunner.requests
            .where(
              (request) => request['action'] == 'conversation.strategy.set',
            )
            .length,
        strategyWritesBeforeRemount,
      );

      final entry = tester.getRect(
        find.byKey(const Key('canonical-group-assistant-control')),
      );
      final field = tester.getRect(
        find.byKey(const Key('agent-conversation-composer-field')),
      );
      expect(entry.height, closeTo(field.height, 0.5));
      expect(entry.top, closeTo(field.top, 0.5));
      expect(entry.bottom, closeTo(field.bottom, 0.5));

      await mouse.moveTo(const Offset(1, 1));
      await tester.pump(const Duration(milliseconds: 220));
      await mouse.moveTo(tester.getCenter(picker));
      await tester.pump();
      expect(
        find.byKey(const Key('canonical-group-strategy-option-rev-auth')),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      await mouse.moveTo(const Offset(1, 1));
      await tester.pump(const Duration(milliseconds: 220));

      await tester.tap(picker);
      await tester.pumpAndSettle();
      expect(openedRevisions, ['rev-auth', 'rev-auth']);

      expect(openedRevisions, ['rev-auth', 'rev-auth']);
      expect(
        conversationRunner.requests.where(
          (request) => request['action'] == 'conversation.membership.add',
        ),
        isNotEmpty,
      );
      expect(gateway.actions, isNot(contains('strategy.run.start')));
      expect(gateway.actions, isNot(contains('strategy.run.cancel')));

      await tester.enterText(find.byType(TextField), 'start the graph');
      await tester.pump();
      await tester.tap(
        find.byKey(const Key('agent-conversation-composer-send')),
      );
      await tester.pumpAndSettle();

      expect(gateway.actions, isNot(contains('strategy.run.start')));
      expect(gateway.startCount, 0);
      expect(callOrder, contains('conversation:conversation.message.post'));
      final post = conversationRunner.requests.lastWhere(
        (request) => request['action'] == 'conversation.message.post',
      );
      expect(post['content'], 'start the graph');
      expect(post.containsKey('mentionedMembershipIds'), isFalse);

      callOrder.clear();
      await tester.enterText(find.byType(TextField), 'continue the graph');
      await tester.pump();
      await tester.tap(
        find.byKey(const Key('agent-conversation-composer-send')),
      );
      await tester.pumpAndSettle();
      expect(callOrder, contains('conversation:conversation.message.post'));
      expect(callOrder, isNot(contains('flywheel:strategy.run.active')));
      expect(callOrder, isNot(contains('flywheel:strategy.run.cancel')));
      expect(callOrder, isNot(contains('flywheel:strategy.run.start')));
      final continuation = conversationRunner.requests.lastWhere(
        (request) => request['action'] == 'conversation.message.post',
      );
      expect(continuation.containsKey('mentionedMembershipIds'), isFalse);
      expect(gateway.startCount, 0);
      final cancelsBeforeClearingStrategy = gateway.actions
          .where((action) => action == 'strategy.run.cancel')
          .length;

      await mouse.moveTo(tester.getCenter(picker));
      await tester.pump();
      await tester.tap(
        find.byKey(const Key('canonical-group-strategy-option-none')),
      );
      await tester.pumpAndSettle();

      expect(openedRevisions, ['rev-auth', 'rev-auth']);
      expect(
        gateway.actions
            .where((action) => action == 'strategy.run.cancel')
            .length,
        cancelsBeforeClearingStrategy,
      );
      expect(find.text('Your Assistant is ready'), findsOneWidget);
      expect(
        find.byKey(const Key('canonical-group-assistant-control')),
        findsOneWidget,
      );
      expect(conversationRunner.strategyRevision, isEmpty);
      expect(
        conversationRunner.requests
            .where(
              (request) => request['action'] == 'conversation.strategy.set',
            )
            .length,
        strategyWritesBeforeRemount + 1,
      );

      await tester.enterText(find.byType(TextField), 'ordinary after exit');
      await tester.pump();
      await tester.tap(
        find.byKey(const Key('agent-conversation-composer-send')),
      );
      await tester.pumpAndSettle();
      expect(gateway.startCount, 0);
    },
  );

  testWidgets(
    'group strategy follow-up posts without cancelling or starting from Dart',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 640);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final callOrder = <String>[];
      final conversationRunner = _GroupConversationRunner(callOrder: callOrder);
      final gateway = _StrategyGateway(callOrder: callOrder);
      final controller = ClientConversationController(
        runner: conversationRunner,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.selectConversation('conversation:group');

      await tester.pumpWidget(
        _groupApp(
          CanonicalGroupConversationPane(
            controller: controller,
            targets: [
              _target('codex', 'Codex'),
              _target('worker-a', 'Worker A'),
            ],
            onCopyText: (_) async {},
            framed: false,
            flywheelGateway: gateway,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final picker = find.byKey(const Key('canonical-group-strategy-picker'));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(picker));
      await tester.pump();
      await tester.tap(
        find.byKey(const Key('canonical-group-strategy-option-rev-auth')),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'start the graph');
      await tester.pump();
      await tester.tap(
        find.byKey(const Key('agent-conversation-composer-send')),
      );
      await tester.pumpAndSettle();
      expect(gateway.startCount, 0);

      callOrder.clear();
      await tester.enterText(find.byType(TextField), 'hi');
      await tester.pump();
      await tester.tap(
        find.byKey(const Key('agent-conversation-composer-send')),
      );
      await tester.pumpAndSettle();
      expect(callOrder, contains('conversation:conversation.message.post'));
      expect(callOrder, isNot(contains('flywheel:strategy.run.cancel')));
      expect(callOrder, isNot(contains('flywheel:strategy.run.start')));
      expect(gateway.startCount, 0);
    },
  );

  testWidgets(
    'Assistant sparkles control pauses only future dispatch and resumes on the next tap',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 640);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final runner = _GroupConversationRunner();
      final controller = ClientConversationController(runner: runner);
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.selectConversation('conversation:group');

      await tester.pumpWidget(
        _groupApp(
          CanonicalGroupConversationPane(
            controller: controller,
            targets: [_target('codex', 'Codex')],
            onCopyText: (_) async {},
            framed: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final toggle = find.byKey(const Key('canonical-group-assistant-toggle'));
      expect(toggle, findsOneWidget);
      await tester.tap(toggle);
      await tester.pump();
      expect(find.text('Your Assistant is paused'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'save without dispatch');
      await tester.tap(
        find.byKey(const Key('agent-conversation-composer-send')),
      );
      await tester.pumpAndSettle();
      expect(
        runner.requests.where(
          (request) => request['action'] == 'conversation.dispatch.after-post',
        ),
        isEmpty,
      );

      await tester.tap(toggle);
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'dispatch again');
      await tester.tap(
        find.byKey(const Key('agent-conversation-composer-send')),
      );
      await tester.pumpAndSettle();
      expect(
        runner.requests.where(
          (request) => request['action'] == 'conversation.dispatch.after-post',
        ),
        hasLength(1),
      );
    },
  );

  testWidgets(
    'Assistant control has no hover editor and matches the input capsule height',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1000, 700);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final runner = _GroupConversationRunner();
      final controller = ClientConversationController(runner: runner);
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.selectConversation('conversation:group');

      await tester.pumpWidget(
        _groupApp(
          CanonicalGroupConversationPane(
            controller: controller,
            targets: [_target('codex', 'Codex')],
            onCopyText: (_) async {},
            framed: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(
        tester.getCenter(
          find.byKey(const Key('canonical-group-assistant-control')),
        ),
      );
      await tester.pump();
      expect(
        find.byKey(const Key('canonical-group-assistant-edit')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('canonical-group-assistant-editor')),
        findsNothing,
      );
      final assistant = tester.getRect(
        find.byKey(const Key('canonical-group-assistant-control')),
      );
      final field = tester.getRect(
        find.byKey(const Key('agent-conversation-composer-field')),
      );
      expect(assistant.height, lessThanOrEqualTo(42));
      expect(assistant.height, closeTo(field.height, 0.5));
      expect(assistant.top, closeTo(field.top, 0.5));
      expect(assistant.bottom, closeTo(field.bottom, 0.5));
    },
  );

  testWidgets(
    'persists a selected strategy when navigation disposes the pane immediately',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 640);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final inspectionBarrier = Completer<void>();
      final conversationRunner = _GroupConversationRunner();
      final gateway = _StrategyGateway(inspectionBarrier: inspectionBarrier);
      final controller = ClientConversationController(
        runner: conversationRunner,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.selectConversation('conversation:group');
      final targets = [
        _target('codex', 'Codex'),
        _target('worker-a', 'Worker A'),
      ];

      Widget groupPane() => _groupApp(
        CanonicalGroupConversationPane(
          controller: controller,
          targets: targets,
          onCopyText: (_) async {},
          framed: false,
          flywheelGateway: gateway,
        ),
      );

      await tester.pumpWidget(groupPane());
      await tester.pumpAndSettle();

      final picker = find.byKey(const Key('canonical-group-strategy-picker'));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(picker));
      await tester.pump();
      await tester.tap(
        find.byKey(const Key('canonical-group-strategy-option-rev-auth')),
      );

      // This models selecting a strategy and immediately leaving the screen,
      // before definition inspection or membership reconciliation completes.
      await tester.pumpWidget(const SizedBox(key: Key('other-interface')));
      await tester.pump();

      expect(conversationRunner.strategyRevision, 'rev-auth');
      expect(
        conversationRunner.requests
            .where(
              (request) => request['action'] == 'conversation.strategy.set',
            )
            .length,
        1,
      );

      inspectionBarrier.complete();
      await tester.pumpAndSettle();
      await tester.pumpWidget(groupPane());
      await tester.pumpAndSettle();

      expect(find.text('Your Assistant is ready'), findsOneWidget);
      expect(
        find.byKey(const Key('canonical-group-assistant-control')),
        findsOneWidget,
      );
      expect(conversationRunner.strategyRevision, 'rev-auth');
    },
  );

  testWidgets(
    'keeps the persisted strategy visible while retrying transient inspection failure',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 640);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final conversationRunner = _GroupConversationRunner();
      final gateway = _StrategyGateway();
      final controller = ClientConversationController(
        runner: conversationRunner,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.selectConversation('conversation:group');

      await tester.pumpWidget(
        _groupApp(
          CanonicalGroupConversationPane(
            controller: controller,
            targets: [_target('codex', 'Codex')],
            onCopyText: (_) async {},
            framed: false,
            flywheelGateway: gateway,
          ),
        ),
      );
      await tester.pumpAndSettle();

      gateway.inspectionFailures = 1;
      expect(await controller.setSelectedStrategyRevision('rev-auth'), isTrue);
      await tester.pumpAndSettle();

      expect(gateway.inspectionCount, 1);
      expect(
        find.byKey(const Key('canonical-group-assistant-control')),
        findsOneWidget,
      );
      expect(find.text('Your Assistant is ready'), findsOneWidget);
      expect(conversationRunner.strategyRevision, 'rev-auth');

      controller.updateDraft('notify projection retry');
      await tester.pumpAndSettle();

      expect(gateway.inspectionCount, 2);
      expect(
        find.byKey(const Key('canonical-group-assistant-control')),
        findsOneWidget,
      );
      expect(find.text('Your Assistant is ready'), findsOneWidget);
    },
  );

  testWidgets(
    'skips the strategy run when the conversation changes while the post is in flight',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 640);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final postBarrier = Completer<void>();
      final conversationRunner = _GroupConversationRunner(
        postBarrier: postBarrier,
      );
      final gateway = _StrategyGateway();
      final controller = ClientConversationController(
        runner: conversationRunner,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.selectConversation('conversation:group');

      await tester.pumpWidget(
        _groupApp(
          CanonicalGroupConversationPane(
            controller: controller,
            targets: [_target('codex', 'Codex')],
            onCopyText: (_) async {},
            framed: false,
            flywheelGateway: gateway,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(await controller.setSelectedStrategyRevision('rev-auth'), isTrue);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('canonical-group-assistant-control')),
        findsOneWidget,
      );

      await tester.enterText(find.byType(TextField), 'race the switch');
      await tester.pump();
      await tester.tap(
        find.byKey(const Key('agent-conversation-composer-send')),
      );
      await tester.pump();

      // The message post is suspended inside the runner while the user
      // navigates to another group conversation.
      await controller.selectConversation('conversation:other');
      await tester.pump();
      expect(controller.selectedConversationId, 'conversation:other');

      postBarrier.complete();
      await tester.pumpAndSettle();

      expect(
        conversationRunner.requests
            .where(
              (request) => request['action'] == 'conversation.message.post',
            )
            .length,
        1,
      );
      expect(gateway.actions, isNot(contains('strategy.run.start')));
      expect(gateway.startCount, 0);
    },
  );

  testWidgets(
    'surfaces a strategy start failure on the group conversation banner',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 640);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final conversationRunner = _GroupConversationRunner()
        ..failStrategyStart = true;
      final gateway = _StrategyGateway();
      final controller = ClientConversationController(
        runner: conversationRunner,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.selectConversation('conversation:group');

      await tester.pumpWidget(
        _groupApp(
          CanonicalGroupConversationPane(
            controller: controller,
            targets: [_target('codex', 'Codex')],
            onCopyText: (_) async {},
            framed: false,
            flywheelGateway: gateway,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(await controller.setSelectedStrategyRevision('rev-auth'), isTrue);
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'hi');
      await tester.pump();
      await tester.tap(
        find.byKey(const Key('agent-conversation-composer-send')),
      );
      await tester.pumpAndSettle();

      expect(controller.failureStage, 'strategy/start');
      expect(controller.failureCode, 'strategy_actor_quota_exhausted');
      expect(controller.failureRef, matches(RegExp(r'^#L-[0-9A-F]{4}$')));
      expect(find.byKey(const Key('canonical-group-failure')), findsOneWidget);
      expect(
        find.byKey(const Key('canonical-group-failure-copy')),
        findsOneWidget,
      );
      expect(find.textContaining(controller.failureRef), findsWidgets);
    },
  );

  testWidgets(
    'strategy dispatch without handles and without a typed error shows no failure',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 640);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final conversationRunner = _GroupConversationRunner()
        ..dispatchPending = true;
      final controller = ClientConversationController(
        runner: conversationRunner,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.selectConversation('conversation:group');

      await tester.pumpWidget(
        _groupApp(
          CanonicalGroupConversationPane(
            controller: controller,
            targets: [_target('codex', 'Codex')],
            onCopyText: (_) async {},
            framed: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(await controller.setSelectedStrategyRevision('rev-auth'), isTrue);
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'hi');
      await tester.pump();
      await tester.tap(
        find.byKey(const Key('agent-conversation-composer-send')),
      );
      await tester.pumpAndSettle();

      expect(controller.failureCode, isEmpty);
      expect(controller.dispatchPending, isFalse);
      expect(find.byKey(const Key('canonical-group-failure')), findsNothing);
      expect(
        tester
            .widget<LicoTopEdgePulse>(
              find.byKey(const Key('conversation-header-running-edge')),
            )
            .enabled,
        isFalse,
      );
    },
  );

  testWidgets(
    'plain group text does not show agent-turn progress while posting',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 640);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final postBarrier = Completer<void>();
      final conversationRunner = _GroupConversationRunner(
        postBarrier: postBarrier,
      );
      final controller = ClientConversationController(
        runner: conversationRunner,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.selectConversation('conversation:group');

      await tester.pumpWidget(
        _groupApp(
          CanonicalGroupConversationPane(
            controller: controller,
            targets: [_target('codex', 'Codex')],
            onCopyText: (_) async {},
            framed: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'plain group note');
      await tester.pump();
      await tester.tap(
        find.byKey(const Key('agent-conversation-composer-send')),
      );
      await tester.pump();

      expect(controller.sending, isTrue);
      expect(controller.dispatchPending, isFalse);
      expect(
        tester
            .widget<LicoTopEdgePulse>(
              find.byKey(const Key('conversation-header-running-edge')),
            )
            .enabled,
        isFalse,
      );

      postBarrier.complete();
      await tester.pumpAndSettle();
      expect(controller.dispatchPending, isFalse);
      expect(
        tester
            .widget<LicoTopEdgePulse>(
              find.byKey(const Key('conversation-header-running-edge')),
            )
            .enabled,
        isFalse,
      );
    },
  );

  testWidgets(
    'group mention attach uses posted turn handles without waiting for activeTurns',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 640);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final conversationRunner = _GroupConversationRunner()
        ..postTurns = [
          {
            'turnHandle': 'dispatch:live',
            'conversationId': 'conversation:group',
            'membershipId': 'membership:codex',
            'agent': 'codex',
          },
        ]
        ..dispatchPending = true;
      final persistent = _PersistentGateway();
      addTearDown(persistent.dispose);
      final controller = ClientConversationController(
        runner: conversationRunner,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.selectConversation('conversation:group');

      await tester.pumpWidget(
        _groupApp(
          CanonicalGroupConversationPane(
            controller: controller,
            targets: [_target('codex', 'Codex')],
            onCopyText: (_) async {},
            framed: false,
            persistentGateway: persistent,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'hello @Codex');
      await tester.pump();
      await tester.tap(
        find.byKey(const Key('agent-conversation-composer-send')),
      );
      await tester.pump();
      await tester.pump();

      expect(controller.liveTurns.single['turnHandle'], 'dispatch:live');
      expect(persistent.attachedHandles, ['dispatch:live']);
      expect(find.text('streaming token'), findsOneWidget);
      expect(
        tester
            .widget<LicoTopEdgePulse>(
              find.byKey(const Key('conversation-header-running-edge')),
            )
            .enabled,
        isTrue,
      );
    },
  );

  testWidgets('new group observer replays a discovered turn from cursor zero', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 640);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final conversationRunner = _GroupConversationRunner();
    final persistent = _PersistentGateway(
      active: const [
        {
          'turnHandle': 'dispatch:existing',
          'conversationId': 'conversation:group',
          'membershipId': 'membership:codex',
          'agent': 'codex',
          'highWater': 9,
        },
      ],
    );
    addTearDown(persistent.dispose);
    final controller = ClientConversationController(runner: conversationRunner);
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.selectConversation('conversation:group');

    await tester.pumpWidget(
      _groupApp(
        CanonicalGroupConversationPane(
          controller: controller,
          targets: [_target('codex', 'Codex')],
          onCopyText: (_) async {},
          framed: false,
          persistentGateway: persistent,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(persistent.attachedHandles, ['dispatch:existing']);
    expect(persistent.attachedAfterCursors, [0]);
    expect(find.text('streaming token'), findsOneWidget);
  });

  testWidgets('observer failure surfaces transport error without cancelling', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 640);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final conversationRunner = _GroupConversationRunner()
      ..postTurns = [
        {
          'turnHandle': 'dispatch:live',
          'conversationId': 'conversation:group',
          'membershipId': 'membership:codex',
          'agent': 'codex',
        },
      ]
      ..dispatchPending = true;
    final persistent = _PersistentGateway();
    addTearDown(persistent.dispose);
    final controller = ClientConversationController(runner: conversationRunner);
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.selectConversation('conversation:group');

    await tester.pumpWidget(
      _groupApp(
        CanonicalGroupConversationPane(
          controller: controller,
          targets: [_target('codex', 'Codex')],
          onCopyText: (_) async {},
          framed: false,
          persistentGateway: persistent,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'hello @Codex');
    await tester.pump();
    await tester.tap(find.byKey(const Key('agent-conversation-composer-send')));
    await tester.pump();
    await tester.pump();
    expect(controller.dispatchPending, isTrue);

    persistent.failObserver();
    for (
      var attempt = 0;
      attempt < 20 && controller.failureCode.isEmpty;
      attempt += 1
    ) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    expect(controller.failureStage, 'conversation/observe');
    expect(controller.failureCode, 'transport_failed');
    expect(controller.dispatchPending, isFalse);
    expect(persistent.cancelCount, 0);
  });

  testWidgets(
    'strategy send shows running edge only after dispatch returns handles',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 640);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final dispatchBarrier = Completer<void>();
      final conversationRunner =
          _GroupConversationRunner(dispatchBarrier: dispatchBarrier)
            ..postTurns = [
              {
                'turnHandle': 'dispatch:live',
                'conversationId': 'conversation:group',
                'agent': 'codex',
              },
            ]
            ..dispatchPending = true;
      final controller = ClientConversationController(
        runner: conversationRunner,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.selectConversation('conversation:group');

      await tester.pumpWidget(
        _groupApp(
          CanonicalGroupConversationPane(
            controller: controller,
            targets: [_target('codex', 'Codex')],
            onCopyText: (_) async {},
            framed: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(await controller.setSelectedStrategyRevision('rev-auth'), isTrue);
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'hi');
      await tester.pump();
      await tester.tap(
        find.byKey(const Key('agent-conversation-composer-send')),
      );
      await tester.pump();

      // While after-post is in flight no handle exists yet, so the running
      // edge stays off even though the composer is busy.
      expect(controller.sending, isTrue);
      expect(controller.dispatchPending, isFalse);
      expect(
        tester
            .widget<LicoTopEdgePulse>(
              find.byKey(const Key('conversation-header-running-edge')),
            )
            .enabled,
        isFalse,
      );

      dispatchBarrier.complete();
      await tester.pump();
      await tester.pump();

      expect(controller.dispatchPending, isTrue);
      expect(controller.liveTurns.single['turnHandle'], 'dispatch:live');
      expect(
        tester
            .widget<LicoTopEdgePulse>(
              find.byKey(const Key('conversation-header-running-edge')),
            )
            .enabled,
        isTrue,
      );
    },
  );
}

Widget _groupApp(Widget child) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    locale: const Locale('en'),
    supportedLocales: LicoStrings.supportedLocales,
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
    ],
    theme: buildLicoTheme(
      platformBrightness: Brightness.dark,
    ).copyWith(platform: TargetPlatform.macOS),
    home: Builder(
      builder: (context) => LayoutPaletteScope(
        palette: layoutPaletteFromColors(context.licoColors),
        child: LayoutAgentsStrategyScope(
          strategy: const AgentsPresentationStrategy.messaging(),
          child: Scaffold(body: child),
        ),
      ),
    ),
  );
}

TargetCandidate _target(String id, String label) => TargetCandidate(
  id: id,
  target: id,
  label: label,
  kind: 'cli',
  status: 'detected',
  configured: true,
  confidence: 1,
  adapterStatus: 'implemented',
  binaryPath: '/fixture/agent',
  adapterCapabilities: const {
    'conversationDriver': 'implemented',
    'conversationProtocol': 'fixture',
    'conversationReadiness': 'ready',
  },
  modelCatalog: const {
    'models': [
      {
        'id': 'model-a',
        'reasoningEfforts': ['low', 'high'],
        'defaultReasoningEffort': 'low',
      },
    ],
  },
  supportedActions: const ['runtime.message.send'],
);

final class _StrategyGateway implements AdaptiveFlywheelGateway {
  _StrategyGateway({this.inspectionBarrier, this.callOrder});

  final Completer<void>? inspectionBarrier;
  final List<String>? callOrder;
  final List<String> actions = [];
  int startCount = 0;
  int inspectionCount = 0;
  int inspectionFailures = 0;
  bool needsHumanInput = false;
  bool failStart = false;

  @override
  Future<Object?> execute(Map<String, dynamic> request) async {
    final action = (request['action'] ?? '').toString();
    actions.add(action);
    callOrder?.add('flywheel:$action');
    if (action == 'strategy.definition.inspect') {
      inspectionCount += 1;
      if (inspectionFailures > 0) {
        inspectionFailures -= 1;
        throw const AdaptiveFlywheelFailure(
          code: 'strategy_inspection_failed',
          recovery: 'Retry strategy inspection.',
          retryable: true,
        );
      }
      await inspectionBarrier?.future;
      return {
        'projection': {
          'status': 'pending',
          'currentStates': <String>[],
          'neighborStates': <String>[],
          'allowedOperations': ['strategy.run.start'],
          'bindings': [
            {
              'slotId': 'entry',
              'valueId': 'codex',
              'ordinal': 0,
              'revision': 1,
            },
            {
              'slotId': 'worker-a',
              'valueId': 'worker-a',
              'ordinal': 0,
              'revision': 1,
            },
          ],
        },
        'workflow': {
          'initial': 'work',
          'actorSlots': [
            {
              'id': 'entry',
              'kind': 'actor',
              'label': 'Entry',
              'required': true,
              'entry': true,
            },
            {
              'id': 'worker-a',
              'kind': 'actor',
              'label': 'Worker A',
              'required': true,
            },
          ],
          'states': [
            {'id': 'work', 'kind': 'actor', 'label': 'Work'},
          ],
          'transitions': <Map<String, dynamic>>[],
        },
      };
    }
    return switch (action) {
      'strategy.definition.list' => [
        {
          'definitionId': 'authorized',
          'name': 'Authorized Graph',
          'version': '1.0.0',
          'revisionDigest': 'rev-auth',
          'semanticsDigest': 'sem-auth',
          'authorized': true,
        },
        {
          'definitionId': 'pending',
          'name': 'Pending Graph',
          'version': '1.0.0',
          'revisionDigest': 'rev-pending',
          'semanticsDigest': 'sem-pending',
          'authorized': false,
        },
      ],
      'strategy.run.active' => {
        'runId': startCount == 0 ? null : 'run-1',
        'needsHumanInput': needsHumanInput,
      },
      'strategy.run.cancel' => {'runId': 'run-1', 'status': 'cancelled'},
      'strategy.run.start' => () {
        startCount += 1;
        if (failStart) {
          throw const AdaptiveFlywheelFailure(
            code: 'strategy_actor_quota_exhausted',
            recovery: 'Review the strategy run.',
          );
        }
        needsHumanInput = false;
        return {'runId': 'run-1', 'needsHumanInput': false};
      }(),
      _ => throw StateError('unexpected action $action'),
    };
  }
}

final class _GroupConversationRunner implements AgentCommandRunner {
  _GroupConversationRunner({
    this.callOrder,
    this.postBarrier,
    this.dispatchBarrier,
  });

  final List<String>? callOrder;
  final Completer<void>? postBarrier;
  final Completer<void>? dispatchBarrier;
  final List<Map<String, dynamic>> requests = [];
  final Map<String, String> addedAgents = {};
  String strategyRevision = '';
  int revision = 2;
  bool failStrategyStart = false;
  bool dispatchPending = false;
  List<Map<String, dynamic>> postTurns = const [];

  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) async {
    final request = Map<String, dynamic>.from(jsonDecode(stdinText) as Map);
    requests.add(request);
    final action = request['action'];
    callOrder?.add('conversation:$action');
    if (action == 'conversation.message.post') {
      await postBarrier?.future;
    }
    if (action == 'conversation.dispatch.after-post') {
      await dispatchBarrier?.future;
    }
    if (action == 'conversation.membership.add') {
      final principal = Map<String, dynamic>.from(request['principal'] as Map);
      addedAgents[(principal['agentId'] ?? '').toString()] =
          (principal['displayName'] ?? '').toString();
    } else if (action == 'conversation.strategy.set') {
      final next = (request['strategyRevision'] ?? '').toString();
      if (next != strategyRevision) {
        strategyRevision = next;
        revision += 1;
      }
    }
    return {
      'ok': true,
      'result': switch (action) {
        'conversation.list' => [_summary(revision)],
        'conversation.get' => _conversation(
          addedAgents,
          strategyRevision: strategyRevision,
          revision: revision,
          conversationId: (request['conversationId'] ?? 'conversation:group')
              .toString(),
        ),
        'conversation.events.page' => {
          'events': <Map<String, dynamic>>[],
          'nextCursor': null,
          'totalCount': 0,
        },
        'conversation.message.post' => {
          'event': <String, dynamic>{
            'id': 'event:posted',
            'conversationId': 'conversation:group',
            'sequence': 2,
            'authorMembershipId': 'membership:owner',
            'kind': 'message',
            'createdAtUnixMs': 2,
            'finalized': true,
            'parts': <Map<String, dynamic>>[],
          },
          'directTurns': <Map<String, dynamic>>[],
          'turns': <Map<String, dynamic>>[],
          'dispatchPending': false,
        },
        'conversation.dispatch.after-post' => {
          'event': <String, dynamic>{'id': request['eventId']},
          'directTurns': <Map<String, dynamic>>[],
          'turns': postTurns,
          'dispatchPending': dispatchPending && !failStrategyStart,
          if (failStrategyStart)
            'strategyError': <String, dynamic>{
              'code': 'strategy_actor_quota_exhausted',
              'stage': 'strategy/start',
            },
        },
        'conversation.membership.add' => <String, dynamic>{},
        'conversation.strategy.set' => <String, dynamic>{},
        'conversation.profile.get' => <String, dynamic>{
          'revision': 0,
          'requiredCapabilities': <String>[],
          'preferredCapabilities': <String>[],
          'skillReferences': <String>[],
        },
        'conversation.profile.update' => <String, dynamic>{
          'profile': request['intent'],
        },
        _ => <String, dynamic>{},
      },
    };
  }

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) =>
      throw UnimplementedError();

  @override
  Stream<Map<String, dynamic>> streamCliJsonLines(List<String> args) =>
      const Stream.empty();

  @override
  Stream<Map<String, dynamic>> streamCliJsonLinesWithStdin(
    List<String> args,
    String stdinText,
  ) => const Stream.empty();
}

Map<String, dynamic> _summary(int revision) => {
  'id': 'conversation:group',
  'title': 'Lico',
  'archived': false,
  'pinned': true,
  'isGroup': true,
  'revision': revision,
  'updatedAtUnixMs': 2,
  'membershipCount': 3,
  'eventCount': 0,
};

Map<String, dynamic> _conversation(
  Map<String, String> addedAgents, {
  required String strategyRevision,
  required int revision,
  String conversationId = 'conversation:group',
}) => {
  'id': conversationId,
  'title': 'Lico',
  'archived': false,
  'pinned': true,
  'isGroup': true,
  'assistantMembershipId': 'membership:codex',
  if (strategyRevision.isNotEmpty) 'strategyRevision': strategyRevision,
  'revision': revision,
  'createdAtUnixMs': 1,
  'updatedAtUnixMs': 2,
  'eventCount': 0,
  'memberships': [
    _membership(
      id: 'membership:owner',
      principalId: 'human:local',
      kind: 'human',
      label: 'Local User',
      access: 'owner',
      conversationId: conversationId,
    ),
    _membership(
      id: 'membership:codex',
      principalId: 'agent:codex',
      kind: 'agent',
      label: 'Codex',
      agentId: 'codex',
      conversationId: conversationId,
    ),
    _membership(
      id: 'membership:claude',
      principalId: 'agent:claude-code',
      kind: 'agent',
      label: 'Claude Code',
      agentId: 'claude-code',
      conversationId: conversationId,
    ),
    for (final entry in addedAgents.entries)
      _membership(
        id: 'membership:${entry.key}',
        principalId: 'agent:${entry.key}',
        kind: 'agent',
        label: entry.value,
        agentId: entry.key,
        conversationId: conversationId,
      ),
  ],
};

Map<String, dynamic> _membership({
  required String id,
  required String principalId,
  required String kind,
  required String label,
  String agentId = '',
  String access = 'member',
  String conversationId = 'conversation:group',
}) => {
  'id': id,
  'conversationId': conversationId,
  'principal': {
    'id': principalId,
    'kind': kind,
    'displayName': label,
    if (agentId.isNotEmpty) 'agentId': agentId,
    'createdAtUnixMs': 1,
  },
  'access': access,
  'status': 'active',
  'joinedAtUnixMs': 1,
};

final class _PersistentGateway implements PersistentAgentConversationGateway {
  _PersistentGateway({List<Map<String, dynamic>> active = const []})
    : _active = List<Map<String, dynamic>>.unmodifiable(active) {
    _chunks = StreamController<AgentDispatchEvent>.broadcast();
  }

  final List<Map<String, dynamic>> _active;
  final List<String> attachedHandles = [];
  final List<int> attachedAfterCursors = [];
  late final StreamController<AgentDispatchEvent> _chunks;
  var cancelCount = 0;

  void failObserver() {
    _chunks.addError(const AgentDispatchStreamException('transport_failed'));
  }

  void dispose() {
    unawaited(_chunks.close());
  }

  @override
  Future<List<Map<String, dynamic>>> activeTurns({
    required String agentId,
    String sessionId = '',
    String conversationId = '',
    Duration waitForChange = Duration.zero,
  }) async => _active;

  @override
  Future<void> ensureRuntime({String conversationId = ''}) async {}

  @override
  Stream<AgentDispatchEvent> attachActiveTurn({
    required String turnHandle,
    required String conversationId,
    int afterCursor = 0,
  }) {
    attachedHandles.add(turnHandle);
    attachedAfterCursors.add(afterCursor);
    scheduleMicrotask(() {
      if (_chunks.isClosed) return;
      _chunks.add(
        const AgentDispatchEvent(
          kind: 'agent.message.chunk',
          payload: {'text': 'streaming token'},
        ),
      );
    });
    return _chunks.stream;
  }

  @override
  Future<AgentDispatchTurnResult> steerActiveTurn({
    required String turnHandle,
    required String conversationId,
    required String text,
  }) async => const AgentDispatchTurnResult(ok: true);

  @override
  Future<AgentDispatchCancelResult> cancelActiveTurn({
    required String turnHandle,
    required String conversationId,
  }) async {
    cancelCount += 1;
    return const AgentDispatchCancelResult(ok: true);
  }
}
