import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/features/agents/contracts/agent_conversation_gateway.dart';
import 'package:licoup/src/application/features/conversations/client_conversation_controller.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/agent_conversation_attachment.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/agent_dispatch_lane.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/conversations/canonical_group_conversation_pane.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_timeline.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_participant_flow.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_agents_strategy.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/shell/layout_palette_projection.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

void main() {
  testWidgets(
    'capsule shows the composed assistant identity and the popover still opens',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 640);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final runner = _AssistantSurfaceRunner();
      final controller = ClientConversationController(runner: runner);
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.selectConversation('conversation:group');

      await tester.pumpWidget(
        _groupApp(
          CanonicalGroupConversationPane(
            controller: controller,
            targets: [
              _target('codex', 'Codex'),
              _target('claude-code', 'Claude Code'),
            ],
            onCopyText: (_) async {},
            framed: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final picker = find.byKey(const Key('canonical-group-strategy-picker'));
      expect(picker, findsOneWidget);
      // Codex with preferred model gpt-5.4 and reasoning effort high.
      expect(
        find.descendant(
          of: picker,
          matching: find.text('Codex · gpt-5.4 · High'),
        ),
        findsOneWidget,
      );
      final colors = tester.element(picker).licoColors;
      expect(
        _dotColor(tester, 'ready'),
        colors.success,
        reason: 'the ready light is the theme success color',
      );

      // The capsule shows no strategy list on hover or tap; with no flywheel
      // editor wired the tap is inert and no panel exists.
      await tester.tap(picker);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('canonical-group-strategy-picker-panel')),
        findsNothing,
      );
      expect(find.text('Automatic adaptation'), findsNothing);
      expect(
        find.descendant(
          of: picker,
          matching: find.text('Codex · gpt-5.4 · High'),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('unconfigured and paused fixtures render gray lights', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 640);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final unconfiguredRunner = _AssistantSurfaceRunner()
      ..assistantMembershipId = '';
    final unconfiguredController = ClientConversationController(
      runner: unconfiguredRunner,
    );
    addTearDown(unconfiguredController.dispose);
    await unconfiguredController.initialize();
    await unconfiguredController.selectConversation('conversation:group');

    await tester.pumpWidget(
      _groupApp(
        CanonicalGroupConversationPane(
          controller: unconfiguredController,
          targets: [_target('codex', 'Codex')],
          onCopyText: (_) async {},
          framed: false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final picker = find.byKey(const Key('canonical-group-strategy-picker'));
    final colors = tester.element(picker).licoColors;
    expect(
      find.descendant(
        of: picker,
        matching: find.text('Configure your Assistant'),
      ),
      findsOneWidget,
    );
    expect(_dotColor(tester, 'unconfigured'), colors.textMuted);

    // Paused: configured assistant, toggle tapped off.
    final runner = _AssistantSurfaceRunner();
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
    await tester.tap(find.byKey(const Key('canonical-group-assistant-toggle')));
    await tester.pump();

    expect(
      find.descendant(
        of: picker,
        matching: find.text('Your Assistant is paused'),
      ),
      findsOneWidget,
    );
    expect(_dotColor(tester, 'paused'), colors.textMuted);
  });

  testWidgets('working fixture pulses green with the working-alone label', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 640);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final runner = _AssistantSurfaceRunner()
      ..postTurns = [
        {
          'turnHandle': 'dispatch:live',
          'conversationId': 'conversation:group',
          'membershipId': 'membership:codex',
          'agent': 'codex',
        },
      ]
      ..dispatchPending = true;
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

    await tester.enterText(find.byType(TextField), 'work alone');
    await tester.pump();
    await tester.tap(find.byKey(const Key('agent-conversation-composer-send')));
    await tester.pump();
    await tester.pump();

    final picker = find.byKey(const Key('canonical-group-strategy-picker'));
    final colors = tester.element(picker).licoColors;
    expect(
      find.descendant(
        of: picker,
        matching: find.text('Your Assistant is working independently'),
      ),
      findsOneWidget,
    );
    expect(_dotColor(tester, 'working'), colors.success);
    // The working light pulses: the dot sits under a live Opacity animation.
    final dot = find.byKey(
      const Key('canonical-group-assistant-status-working'),
    );
    expect(
      find.ancestor(of: dot, matching: find.byType(Opacity)),
      findsWidgets,
    );
  });

  testWidgets(
    'coordinating fixture keeps the working light and counts subagents',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 640);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final runner = _AssistantSurfaceRunner()
        ..postTurns = [
          {
            'turnHandle': 'dispatch:assistant',
            'conversationId': 'conversation:group',
            'membershipId': 'membership:codex',
            'agent': 'codex',
          },
          {
            'turnHandle': 'dispatch:member',
            'conversationId': 'conversation:group',
            'membershipId': 'membership:claude',
            'agent': 'claude-code',
          },
        ]
        ..dispatchPending = true;
      final persistent = _PersistentGateway();
      addTearDown(persistent.dispose);
      final controller = ClientConversationController(runner: runner);
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.selectConversation('conversation:group');

      await tester.pumpWidget(
        _groupApp(
          CanonicalGroupConversationPane(
            controller: controller,
            targets: [
              _target('codex', 'Codex'),
              _target('claude-code', 'Claude Code'),
            ],
            onCopyText: (_) async {},
            framed: false,
            persistentGateway: persistent,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'coordinate');
      await tester.pump();
      await tester.tap(
        find.byKey(const Key('agent-conversation-composer-send')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));

      expect(persistent.attachedHandles, [
        'dispatch:assistant',
        'dispatch:member',
      ]);
      final picker = find.byKey(const Key('canonical-group-strategy-picker'));
      expect(
        find.descendant(
          of: picker,
          matching: find.text('Your Assistant is coordinating 1 Subagent'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('canonical-group-assistant-status-working')),
        findsOneWidget,
      );
    },
  );

  testWidgets('waiting fixture keeps the identity label behind a blue light', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 640);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final runner = _AssistantSurfaceRunner();
    final persistent = _PersistentGateway(
      waiting: true,
      active: const [
        {
          'turnHandle': 'dispatch:waiting',
          'conversationId': 'conversation:group',
          'membershipId': 'membership:codex',
          'agent': 'codex',
        },
      ],
    );
    addTearDown(persistent.dispose);
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
          persistentGateway: persistent,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pump();

    final picker = find.byKey(const Key('canonical-group-strategy-picker'));
    final colors = tester.element(picker).licoColors;
    expect(
      find.descendant(
        of: picker,
        matching: find.text('Codex · gpt-5.4 · High'),
      ),
      findsOneWidget,
    );
    expect(_dotColor(tester, 'waiting'), colors.accent);
  });

  testWidgets('failure fixture keeps the identity label behind a red light', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 640);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final runner = _AssistantSurfaceRunner();
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

    controller.surfaceFailure('send', 'adapter_offline');
    await tester.pumpAndSettle();

    final picker = find.byKey(const Key('canonical-group-strategy-picker'));
    final colors = tester.element(picker).licoColors;
    expect(
      find.descendant(
        of: picker,
        matching: find.text('Codex · gpt-5.4 · High'),
      ),
      findsOneWidget,
    );
    expect(_dotColor(tester, 'failure'), colors.error);
    expect(find.byKey(const Key('canonical-group-failure')), findsOneWidget);
  });

  testWidgets(
    'plus menu floats exactly above the button, expands on hover, and dismisses outside',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 640);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final runner = _AssistantSurfaceRunner();
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

      final button = find.byKey(const Key('canonical-group-assistant-actions'));
      final field = find.byKey(const Key('agent-conversation-composer-field'));
      expect(button, findsOneWidget);
      final buttonRect = tester.getRect(button);
      final fieldRect = tester.getRect(field);
      expect(
        find.byKey(const Key('canonical-group-assistant-actions-menu')),
        findsNothing,
      );

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);

      await tester.tap(
        find.byKey(const Key('canonical-group-assistant-actions-trigger')),
      );
      await tester.pumpAndSettle();

      final menu = find.byKey(
        const Key('canonical-group-assistant-actions-menu'),
      );
      expect(menu, findsOneWidget);
      // Detached overlay: the composer's laid-out geometry is untouched.
      expect(tester.getRect(field), fieldRect);
      expect(tester.getRect(button), buttonRect);
      // Exactly above the button: bottom edge at button top minus the gap,
      // left edges aligned.
      final menuRect = tester.getRect(menu);
      expect(menuRect.bottom, closeTo(buttonRect.top - 8, 0.5));
      expect(menuRect.left, closeTo(buttonRect.left, 0.5));

      final attachments = find.byKey(
        const Key('canonical-group-action-attachments'),
      );
      final newConversation = find.byKey(
        const Key('canonical-group-action-new-conversation'),
      );
      expect(attachments, findsOneWidget);
      expect(newConversation, findsOneWidget);
      expect(
        find.byKey(const Key('canonical-group-action-discard-images')),
        findsNothing,
      );
      // Attachments is nearest the button; new conversation above it.
      expect(
        tester.getRect(attachments).bottom,
        greaterThan(tester.getRect(newConversation).bottom),
      );
      expect(find.text('Attachments'), findsNothing);

      final collapsedWidth = tester.getSize(attachments).width;
      expect(collapsedWidth, closeTo(40, 0.5));
      final collapsedLeft = tester.getRect(attachments).left;

      await mouse.moveTo(tester.getCenter(attachments));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 220));

      expect(find.text('Attachments'), findsOneWidget);
      final expandedRect = tester.getRect(attachments);
      expect(expandedRect.width, greaterThan(collapsedWidth + 20));
      // The icon slot stays pinned left: the circle expands rightward only.
      expect(expandedRect.left, closeTo(collapsedLeft, 0.5));

      await mouse.moveTo(Offset.zero);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 220));
      expect(find.text('Attachments'), findsNothing);

      await tester.tapAt(const Offset(600, 200));
      await tester.pumpAndSettle();
      expect(menu, findsNothing);
      expect(tester.getRect(field), fieldRect);
    },
  );

  testWidgets('new-conversation action rotates the assistant thread in place', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 640);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final runner = _AssistantSurfaceRunner();
    final controller = ClientConversationController(runner: runner);
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.selectConversation('conversation:group');

    await tester.pumpWidget(
      _groupApp(
        CanonicalGroupConversationPane(
          controller: controller,
          targets: [
            _target('codex', 'Codex'),
            _target('claude-code', 'Claude Code'),
          ],
          onCopyText: (_) async {},
          framed: false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('canonical-group-assistant-actions-trigger')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('canonical-group-action-new-conversation')),
    );
    await tester.pumpAndSettle();

    final rotation = runner.requests
        .map((request) => request['action'])
        .where(
          (action) =>
              action == 'conversation.membership.leave' ||
              action == 'conversation.membership.add' ||
              action == 'conversation.assistant.set' ||
              action == 'conversation.profile.update',
        )
        .toList(growable: false);
    expect(rotation, [
      'conversation.membership.leave',
      'conversation.membership.add',
      'conversation.assistant.set',
      'conversation.profile.update',
    ]);

    final leave = runner.requests.firstWhere(
      (request) => request['action'] == 'conversation.membership.leave',
    );
    expect(leave['membershipId'], 'membership:codex');
    final add = runner.requests.firstWhere(
      (request) => request['action'] == 'conversation.membership.add',
    );
    final principal = Map<String, dynamic>.from(add['principal'] as Map);
    expect(principal['id'], 'agent:codex');
    expect(principal['agentId'], 'codex');
    expect(principal['displayName'], 'Codex');

    final rotatedId = runner.assistantMembershipId;
    expect(rotatedId, isNot('membership:codex'));
    final assistantSet = runner.requests.firstWhere(
      (request) => request['action'] == 'conversation.assistant.set',
    );
    expect(assistantSet['membershipId'], rotatedId);
    final profileUpdate = runner.requests.firstWhere(
      (request) => request['action'] == 'conversation.profile.update',
    );
    expect(profileUpdate['membershipId'], rotatedId);
    final intent = Map<String, dynamic>.from(profileUpdate['intent'] as Map);
    expect(intent['preferredModel'], 'gpt-5.4');
    expect(intent['preferredReasoningEffort'], 'high');

    // The pane never leaves the group: same id, same agent, new Membership.
    expect(controller.selectedConversationId, 'conversation:group');
    final reloaded = controller.selectedConversation;
    expect(reloaded, isNotNull);
    expect(reloaded!.id, 'conversation:group');
    expect(reloaded.assistantMembership?.id, rotatedId);
    expect(reloaded.assistantMembership?.principal.agentId, 'codex');
    expect(controller.failureCode, isEmpty);
    expect(
      find.byKey(const Key('canonical-group-conversation-pane')),
      findsOneWidget,
    );
    // The carried-over profile drives the identity label again.
    final picker = find.byKey(const Key('canonical-group-strategy-picker'));
    expect(
      find.descendant(
        of: picker,
        matching: find.text('Codex · gpt-5.4 · High'),
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'typed slash-new in the group composer runs the same refresh and never posts',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 640);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final runner = _AssistantSurfaceRunner();
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

      await tester.enterText(find.byType(TextField), '/new');
      await tester.pump();
      await tester.tap(
        find.byKey(const Key('agent-conversation-composer-send')),
      );
      await tester.pumpAndSettle();

      expect(
        runner.requests.where(
          (request) => request['action'] == 'conversation.message.post',
        ),
        isEmpty,
      );
      final rotation = runner.requests
          .map((request) => request['action'])
          .where(
            (action) =>
                action == 'conversation.membership.leave' ||
                action == 'conversation.membership.add' ||
                action == 'conversation.assistant.set' ||
                action == 'conversation.profile.update',
          )
          .toList(growable: false);
      expect(rotation, [
        'conversation.membership.leave',
        'conversation.membership.add',
        'conversation.assistant.set',
        'conversation.profile.update',
      ]);
      expect(controller.selectedConversationId, 'conversation:group');
      expect(
        controller.selectedConversation?.assistantMembership?.principal.agentId,
        'codex',
      );
    },
  );

  testWidgets('busy assistant refuses the refresh with assistant_turn_active', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 640);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final runner = _AssistantSurfaceRunner()
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
          persistentGateway: persistent,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'keep busy');
    await tester.pump();
    await tester.tap(find.byKey(const Key('agent-conversation-composer-send')));
    await tester.pump();
    await tester.pump();
    expect(controller.dispatchPending, isTrue);

    await tester.tap(
      find.byKey(const Key('canonical-group-assistant-actions-trigger')),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const Key('canonical-group-action-new-conversation')),
    );
    await tester.pump();

    expect(
      runner.requests.where(
        (request) =>
            request['action'] == 'conversation.membership.leave' ||
            request['action'] == 'conversation.membership.add',
      ),
      isEmpty,
    );
    expect(controller.failureCode, 'assistant_turn_active');
    expect(find.byKey(const Key('canonical-group-failure')), findsOneWidget);
    expect(runner.assistantMembershipId, 'membership:codex');
  });

  testWidgets(
    'staged images render as a pending draft and post with the shared attachment shape',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 640);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final runner = _AssistantSurfaceRunner();
      final controller = ClientConversationController(runner: runner);
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.selectConversation('conversation:group');

      var staged = <ConversationAttachment>[];
      await tester.pumpWidget(
        _groupApp(
          StatefulBuilder(
            builder: (context, setState) {
              return CanonicalGroupConversationPane(
                controller: controller,
                targets: [_target('codex', 'Codex')],
                onCopyText: (_) async {},
                framed: false,
                composerAttachments: staged,
                assistantSupportsImageAttachments: true,
                onPickComposerImages: () => setState(() {
                  staged = const [
                    ConversationAttachment(
                      id: 'selection-1',
                      name: 'first.png',
                      mediaType: 'image/png',
                      path: 'fixtures/first.png',
                    ),
                    ConversationAttachment(
                      id: 'selection-2',
                      name: 'second.jpg',
                      mediaType: 'image/jpeg',
                      path: 'fixtures/second.jpg',
                    ),
                  ];
                }),
                onClearComposerImages: () => setState(() => staged = const []),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('canonical-group-assistant-actions-trigger')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('canonical-group-action-attachments')),
      );
      await tester.pumpAndSettle();

      expect(staged, hasLength(2));
      // Both images render as the pending draft in the group timeline.
      final draftMessages = _flowMessagesWithImages(tester);
      expect(draftMessages, hasLength(1));
      expect(draftMessages.single.images, hasLength(2));
      expect(draftMessages.single.role, 'user');

      // Staged images enable an empty-text send.
      await tester.tap(
        find.byKey(const Key('agent-conversation-composer-send')),
      );
      await tester.pumpAndSettle();

      final post = runner.requests.lastWhere(
        (request) => request['action'] == 'conversation.message.post',
      );
      expect(post['content'], '');
      expect(post['attachments'], [
        {
          'path': 'fixtures/first.png',
          'name': 'first.png',
          'mediaType': 'image/png',
        },
        {
          'path': 'fixtures/second.jpg',
          'name': 'second.jpg',
          'mediaType': 'image/jpeg',
        },
      ]);
      expect(controller.failureCode, isEmpty);
      expect(find.byKey(const Key('canonical-group-failure')), findsNothing);
      // The composer scope cleared after the successful send.
      expect(staged, isEmpty);
      expect(_flowMessagesWithImages(tester), isEmpty);
    },
  );

  testWidgets(
    'send fails closed with attachment_transport_unsupported and discard clears the scope',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 640);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final runner = _AssistantSurfaceRunner();
      final controller = ClientConversationController(runner: runner);
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.selectConversation('conversation:group');

      var staged = <ConversationAttachment>[];
      await tester.pumpWidget(
        _groupApp(
          StatefulBuilder(
            builder: (context, setState) {
              return CanonicalGroupConversationPane(
                controller: controller,
                targets: [_target('codex', 'Codex')],
                onCopyText: (_) async {},
                framed: false,
                composerAttachments: staged,
                onPickComposerImages: () => setState(() {
                  staged = const [
                    ConversationAttachment(
                      id: 'selection-1',
                      name: 'first.png',
                      mediaType: 'image/png',
                      path: 'fixtures/first.png',
                    ),
                  ];
                }),
                onClearComposerImages: () => setState(() => staged = const []),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('canonical-group-assistant-actions-trigger')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('canonical-group-action-attachments')),
      );
      await tester.pumpAndSettle();
      expect(staged, hasLength(1));

      await tester.enterText(find.byType(TextField), 'with images');
      await tester.pump();
      await tester.tap(
        find.byKey(const Key('agent-conversation-composer-send')),
      );
      await tester.pumpAndSettle();

      // Fail closed: nothing posted, the banner carries the code, and the
      // composer restored the text while the scope kept the images.
      expect(
        runner.requests.where(
          (request) => request['action'] == 'conversation.message.post',
        ),
        isEmpty,
      );
      expect(controller.failureCode, 'attachment_transport_unsupported');
      expect(find.byKey(const Key('canonical-group-failure')), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        'with images',
      );
      expect(staged, hasLength(1));
      expect(_flowMessagesWithImages(tester), hasLength(1));

      await tester.tap(
        find.byKey(const Key('canonical-group-assistant-actions-trigger')),
      );
      await tester.pumpAndSettle();
      final discard = find.byKey(
        const Key('canonical-group-action-discard-images'),
      );
      expect(discard, findsOneWidget);
      await tester.tap(discard);
      await tester.pumpAndSettle();

      expect(staged, isEmpty);
      expect(_flowMessagesWithImages(tester), isEmpty);
    },
  );
}

/// Timeline messages carrying image attachments, projected by the participant
/// flow (the pending draft renders as the only such message in these tests).
/// An empty conversation unmounts the flow entirely; treat that as no images.
List<AgentConversationMessage> _flowMessagesWithImages(WidgetTester tester) {
  final flowFinder = find.byType(MessagingParticipantFlow);
  if (flowFinder.evaluate().isEmpty) return const [];
  final flow = tester.widget<MessagingParticipantFlow>(flowFinder);
  return [
    for (final item in flow.items)
      if (item is ConversationMessageTimelineItem &&
          item.message.images.isNotEmpty)
        item.message,
  ];
}

Color? _dotColor(WidgetTester tester, String state) {
  final dot = find.byKey(Key('canonical-group-assistant-status-$state'));
  expect(dot, findsOneWidget);
  final container = tester.widget<Container>(dot);
  final decoration = container.decoration;
  return decoration is BoxDecoration ? decoration.color : null;
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

/// Fake conversation bridge with membership-rotation semantics: leave marks
/// the membership left (and clears the assistant designation), add re-joins
/// the same principal under a fresh Membership id with a default Profile, and
/// assistant.set enforces the current conversation revision.
final class _AssistantSurfaceRunner implements AgentCommandRunner {
  final List<Map<String, dynamic>> requests = [];
  int revision = 2;
  String assistantMembershipId = 'membership:codex';
  bool dispatchPending = false;
  List<Map<String, dynamic>> postTurns = const [];
  int _rotationCount = 0;

  final Map<String, Map<String, dynamic>> _profiles = {
    'membership:codex': {
      'revision': 0,
      'responsibility': 'assistant',
      'requiredCapabilities': <String>[],
      'preferredCapabilities': <String>[],
      'skillReferences': <String>[],
      'preferredModel': 'gpt-5.4',
      'preferredReasoningEffort': 'high',
    },
  };

  final List<Map<String, dynamic>> _memberships = [
    _membership(
      id: 'membership:owner',
      principalId: 'human:local',
      kind: 'human',
      label: 'Local User',
      access: 'owner',
    ),
    _membership(
      id: 'membership:codex',
      principalId: 'agent:codex',
      kind: 'agent',
      label: 'Codex',
      agentId: 'codex',
    ),
    _membership(
      id: 'membership:claude',
      principalId: 'agent:claude-code',
      kind: 'agent',
      label: 'Claude Code',
      agentId: 'claude-code',
    ),
  ];

  Iterable<Map<String, dynamic>> get _activeMemberships =>
      _memberships.where((membership) => membership['status'] == 'active');

  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) async {
    final request = Map<String, dynamic>.from(jsonDecode(stdinText) as Map);
    requests.add(request);
    final action = (request['action'] ?? '').toString();
    switch (action) {
      case 'conversation.membership.leave':
        final membershipId = (request['membershipId'] ?? '').toString();
        for (final membership in _memberships) {
          if (membership['id'] == membershipId) {
            membership['status'] = 'left';
            membership['leftAtUnixMs'] = 3;
          }
        }
        if (assistantMembershipId == membershipId) {
          assistantMembershipId = '';
        }
        revision += 1;
        return {'ok': true, 'result': <String, dynamic>{}};
      case 'conversation.membership.add':
        final principal = Map<String, dynamic>.from(
          request['principal'] as Map,
        );
        final agentId = (principal['agentId'] ?? '').toString();
        final membershipId = 'membership:$agentId-rotated-${++_rotationCount}';
        final membership = <String, dynamic>{
          'id': membershipId,
          'conversationId': 'conversation:group',
          'principal': {
            'id': principal['id'],
            'kind': principal['kind'],
            'displayName': principal['displayName'],
            if (agentId.isNotEmpty) 'agentId': agentId,
            'createdAtUnixMs': 1,
          },
          'access': (request['access'] ?? 'member').toString(),
          'status': 'active',
          'joinedAtUnixMs': 3,
        };
        _memberships.add(membership);
        _profiles[membershipId] = {
          'revision': 0,
          'responsibility': 'member',
          'requiredCapabilities': <String>[],
          'preferredCapabilities': <String>[],
          'skillReferences': <String>[],
        };
        revision += 1;
        return {'ok': true, 'result': membership};
      case 'conversation.assistant.set':
        final expected = (request['expectedRevision'] as num?)?.toInt() ?? -1;
        if (expected != revision) {
          return {
            'ok': false,
            'error': <String, dynamic>{'code': 'conversation_revision_stale'},
          };
        }
        assistantMembershipId = (request['membershipId'] ?? '').toString();
        revision += 1;
        return {'ok': true, 'result': <String, dynamic>{}};
      case 'conversation.profile.update':
        final membershipId = (request['membershipId'] ?? '').toString();
        final profile = _profiles[membershipId];
        if (profile == null) {
          return {
            'ok': false,
            'error': <String, dynamic>{'code': 'membership_not_found'},
          };
        }
        final intent = Map<String, dynamic>.from(request['intent'] as Map);
        _profiles[membershipId] = {
          ...profile,
          ...intent,
          'revision': (profile['revision'] as int) + 1,
        };
        return {
          'ok': true,
          'result': <String, dynamic>{'profile': _profiles[membershipId]},
        };
    }
    return {
      'ok': true,
      'result': switch (action) {
        'conversation.list' => [
          {
            'id': 'conversation:group',
            'title': 'Lico',
            'archived': false,
            'pinned': true,
            'isGroup': true,
            'revision': revision,
            'updatedAtUnixMs': 2,
            'membershipCount': _activeMemberships.length,
            'eventCount': 0,
          },
        ],
        'conversation.get' => {
          'id': 'conversation:group',
          'title': 'Lico',
          'archived': false,
          'pinned': true,
          'isGroup': true,
          if (assistantMembershipId.isNotEmpty)
            'assistantMembershipId': assistantMembershipId,
          'revision': revision,
          'createdAtUnixMs': 1,
          'updatedAtUnixMs': 2,
          'eventCount': 0,
          'memberships': _memberships,
        },
        'conversation.events.page' => {
          'events': <Map<String, dynamic>>[],
          'nextCursor': null,
          'totalCount': 0,
        },
        'conversation.message.post' => {
          'event': <String, dynamic>{
            'id': 'event:posted-${requests.length}',
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
          'dispatchPending': dispatchPending,
        },
        'conversation.profile.get' =>
          _profiles[(request['membershipId'] ?? '').toString()],
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

Map<String, dynamic> _membership({
  required String id,
  required String principalId,
  required String kind,
  required String label,
  String agentId = '',
  String access = 'member',
}) => {
  'id': id,
  'conversationId': 'conversation:group',
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

/// Minimal persistent gateway: discovers the configured active turns and emits
/// one projection frame per attach — a waiting-for-human turn state for the
/// waiting fixture, a plain chunk otherwise.
final class _PersistentGateway implements PersistentAgentConversationGateway {
  _PersistentGateway({
    List<Map<String, dynamic>> active = const [],
    this.waiting = false,
  }) : _active = List<Map<String, dynamic>>.unmodifiable(active) {
    _chunks = StreamController<AgentDispatchEvent>.broadcast();
  }

  final List<Map<String, dynamic>> _active;
  final bool waiting;
  final List<String> attachedHandles = [];
  late final StreamController<AgentDispatchEvent> _chunks;

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
    scheduleMicrotask(() {
      if (_chunks.isClosed) return;
      _chunks.add(
        waiting
            ? const AgentDispatchEvent(
                kind: 'agent.turn.processing',
                payload: {
                  'turnState': {'state': 'waiting-for-human'},
                  'cursor': 1,
                },
              )
            : const AgentDispatchEvent(
                kind: 'agent.message.chunk',
                payload: {'text': 'streaming token', 'cursor': 1},
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
  }) async => const AgentDispatchCancelResult(ok: true);
}
