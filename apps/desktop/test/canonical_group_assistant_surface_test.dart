import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_pane.dart';
import 'package:licoup/src/frontend/shared/messaging/conversation_motion/orb_waiting_indicator.dart';

import 'package:licoup/src/application/features/agents/contracts/agent_conversation_gateway.dart';
import 'package:licoup/src/application/features/conversations/client_conversation_controller.dart';
import 'package:licoup/src/contracts/conversation_native_port.dart';
import 'package:licoup/src/contracts/agent_conversation_attachment.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/agent_dispatch_lane.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_timeline.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_participant_flow.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_agents_strategy.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/shared/layout_palette_projection.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

import 'support/canonical_group/canonical_group_binding_fixture.dart';

void main() {
  for (final retired in [false, true]) {
    testWidgets(
      'group history remains readable without visible Agent seats (retired: $retired)',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1000, 760);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final runner = _AssistantSurfaceRunner()..assistantMembershipId = '';
        runner._memberships.removeWhere(
          (item) => item['id'] != 'membership:owner',
        );
        if (retired) {
          runner._memberships.add(
            _membership(
              id: 'membership:retired',
              principalId: 'agent:kimi-desktop',
              kind: 'agent',
              label: 'Kimi',
              agentId: 'kimi-desktop',
            ),
          );
        }
        runner.historyEvents.add({
          'id': 'event:history',
          'conversationId': 'conversation:group',
          'sequence': 1,
          'authorMembershipId': 'membership:owner',
          'kind': 'message',
          'createdAtUnixMs': 1,
          'finalized': true,
          'parts': [
            {
              'id': 'part:history',
              'eventId': 'event:history',
              'ordinal': 0,
              'kind': 'text',
              'content': 'Saved group history',
              'createdAtUnixMs': 1,
            },
          ],
        });
        final controller = ClientConversationController(native: runner);
        addTearDown(controller.dispose);
        await controller.initialize();
        await controller.selectConversation('conversation:group');
        await tester.pumpWidget(
          _groupApp(
            CanonicalGroupConversationPaneFixture(
              controller: controller,
              targets: const [],
              onCopyText: (_) async {},
              framed: false,
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        final pane = tester.widget<AgentConversationActivePane>(
          find.byType(AgentConversationActivePane),
        );
        expect(pane.state.session!.messages.single.text, 'Saved group history');
        expect(find.textContaining('Saved group history'), findsWidgets);
        expect(find.byKey(const Key('canonical-group-roster')), findsNothing);
        expect(find.byType(TextField), findsOneWidget);
        controller.dispose();
      },
    );
  }

  testWidgets(
    'custom Membership alias is used by completion and roster mention',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1000, 760);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final runner = _AssistantSurfaceRunner();
      final member = runner._memberships.firstWhere(
        (item) => item['id'] == 'membership:claude',
      );
      (member['principal'] as Map)['displayName'] = 'Reviewer';
      final controller = ClientConversationController(native: runner);
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.selectConversation('conversation:group');
      await tester.pumpWidget(
        _groupApp(
          CanonicalGroupConversationPaneFixture(
            controller: controller,
            targets: [_target('claude-code', 'Claude Code')],
            onCopyText: (_) async {},
            framed: false,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(find.byType(TextField), '@Rev');
      await tester.pump();
      await tester.tap(
        find.byKey(const Key('agent-conversation-mention-claude-code')),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(controller.draft, '@Reviewer ');
      await tester.enterText(find.byType(TextField), '');
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.byKey(const Key('canonical-group-menu-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('canonical-group-roster-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('canonical-group-roster-agent-claude-code')),
      );
      await tester.pump();
      expect(controller.draft, '@Reviewer ');
      final membership = controller.selectedConversation!.activeAgentMemberships
          .firstWhere((item) => item.principal.agentId == 'claude-code');
      expect(controller.draft.trim(), '@${membership.principal.displayName}');
      expect(
        runner.requests.where(
          (request) => request['action'] == 'conversation.membership.add',
        ),
        isEmpty,
      );
      controller.dispose();
    },
  );

  testWidgets(
    'candidate record id cannot revive or mention a retired adapter Membership',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1000, 760);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final opened = <String>[];
      final runner = _AssistantSurfaceRunner();
      runner._memberships.insert(
        0,
        _membership(
          id: 'membership:retired',
          principalId: 'agent:kimi',
          kind: 'agent',
          label: 'Retired Kimi',
          agentId: 'kimi',
        ),
      );
      final member = runner._memberships.firstWhere(
        (item) => item['id'] == 'membership:claude',
      );
      (member['principal'] as Map)['agentId'] = 'kimi-code';
      (member['principal'] as Map)['displayName'] = 'Reviewer';
      final controller = ClientConversationController(native: runner);
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.selectConversation('conversation:group');
      await tester.pumpWidget(
        _groupApp(
          CanonicalGroupConversationPaneFixture(
            controller: controller,
            targets: [
              TargetCandidate(
                id: 'kimi',
                target: 'kimi-code',
                label: 'Kimi Code',
                kind: 'cli',
                status: 'detected',
                configured: true,
                confidence: 1,
                manual: true,
                adapterStatus: 'implemented',
                binaryPath: '/fixture/agent',
              ),
            ],
            onCopyText: (_) async {},
            framed: false,
            onOpenAgentConversations: opened.add,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final state = tester
          .widget<AgentConversationActivePane>(
            find.byType(AgentConversationActivePane),
          )
          .state;
      expect(
        state.participantTargets.map((target) => target.target),
        isNot(contains('kimi')),
      );
      expect(state.composerMentionLabels.containsKey('kimi'), isFalse);
      expect(
        find.byKey(const Key('canonical-group-roster-agent-kimi')),
        findsNothing,
      );
      await tester.enterText(find.byType(TextField), '@Rev');
      await tester.pump();
      await tester.tap(
        find.byKey(const Key('agent-conversation-mention-kimi-code')),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(controller.draft, '@Reviewer ');
      await tester.enterText(find.byType(TextField), '');
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.byKey(const Key('canonical-group-menu-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('canonical-group-roster-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('canonical-group-roster-agent-kimi-code')),
      );
      await tester.pump(const Duration(milliseconds: 350));
      expect(controller.draft, '@Reviewer ');
      final membership = controller.selectedConversation!.activeAgentMemberships
          .firstWhere((item) => item.principal.agentId == 'kimi-code');
      expect(controller.draft.trim(), '@${membership.principal.displayName}');
      expect(
        runner.requests.where(
          (request) => request['action'] == 'conversation.membership.add',
        ),
        isEmpty,
      );
      await tester.tap(
        find.byKey(const Key('canonical-group-roster-agent-kimi-code')),
      );
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(
        find.byKey(const Key('canonical-group-roster-agent-kimi-code')),
      );
      await tester.pump();
      expect(opened, ['kimi-code']);
      await tester.pump(const Duration(milliseconds: 350));
      controller.dispose();
    },
  );

  testWidgets(
    'canonical dispatch projects a stable waiting reply before first text',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1000, 760);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final runner = _AssistantSurfaceRunner()
        ..postTurns = [
          {
            'turnHandle': 'dispatch:first',
            'conversationId': 'conversation:group',
            'membershipId': 'membership:codex',
            'agent': 'codex',
          },
        ]
        ..dispatchPending = true;
      final gateway = _PersistentGateway(acceptOnly: true);
      addTearDown(gateway.dispose);
      final controller = ClientConversationController(native: runner);
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.selectConversation('conversation:group');
      await tester.pumpWidget(
        _groupApp(
          CanonicalGroupConversationPaneFixture(
            controller: controller,
            targets: [_target('codex', 'Codex')],
            onCopyText: (_) async {},
            framed: false,
            reduceMotion: false,
            persistentGateway: gateway,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(
        find.byType(TextField),
        'Explain this synthetic example',
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const Key('agent-conversation-composer-send')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(gateway.attachedHandles, ['dispatch:first']);
      expect(find.byType(OrbWaitingIndicator), findsOneWidget);
      final before = tester
          .widget<AgentConversationActivePane>(
            find.byType(AgentConversationActivePane),
          )
          .state
          .liveMessages
          .singleWhere((message) => message.waitingForReply);
      expect(before.executionReference?.conversationId, 'conversation:group');
      expect(before.executionReference?.membershipId, 'membership:codex');
      expect(before.executionReference?.turnHandle, 'dispatch:first');
      gateway.emitReply('First text from the actual Membership observer');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(find.byType(OrbWaitingIndicator), findsNothing);
      expect(
        find.textContaining('actual Membership observer', findRichText: true),
        findsOneWidget,
      );
      final after = tester
          .widget<AgentConversationActivePane>(
            find.byType(AgentConversationActivePane),
          )
          .state
          .liveMessages
          .singleWhere(
            (message) => message.kind == AgentConversationMessageKind.assistant,
          );
      expect(after.id, before.id);
      expect(after.executionReference, before.executionReference);
      expect(
        find.byKey(const Key('conversation-execution-menu')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      controller.dispose();
    },
  );

  testWidgets('assistant name stays separate from the Flywheel entry', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 640);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final runner = _AssistantSurfaceRunner();
    final controller = ClientConversationController(native: runner);
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.selectConversation('conversation:group');

    await tester.pumpWidget(
      _groupApp(
        CanonicalGroupConversationPaneFixture(
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
    // The expected label is derived from the mutable backend fixture. The
    // regression must never encode a real Agent + Model pairing.
    expect(
      find.descendant(
        of: find.byKey(const Key('canonical-group-assistant-control')),
        matching: find.text(runner.assistantDisplayName),
      ),
      findsOneWidget,
    );
    final colors = tester.element(picker).licoColors;
    expect(
      _nameColor(tester, 'ready'),
      colors.text,
      reason: 'the active name uses the readable text color',
    );

    // The capsule shows no strategy list on hover or tap; with no flywheel
    // editor wired the tap is inert and no panel exists.
    await tester.tap(picker);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('canonical-group-strategy-picker-panel')),
      findsNothing,
    );
    expect(find.text('Adaptive Flywheel'), findsWidgets);
    expect(
      find.descendant(
        of: find.byKey(const Key('canonical-group-assistant-control')),
        matching: find.text(runner.assistantDisplayName),
      ),
      findsOneWidget,
    );
    controller.dispose();
  });

  testWidgets(
    'Flywheel return refreshes profile without changing the assistant name',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 640);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final runner = _AssistantSurfaceRunner();
      final controller = ClientConversationController(native: runner);
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.selectConversation('conversation:group');

      await tester.pumpWidget(
        _groupApp(
          CanonicalGroupConversationPaneFixture(
            controller: controller,
            targets: [_target('codex', 'Codex')],
            onCopyText: (_) async {},
            onOpenAdaptiveFlywheel: (_) async {
              runner.configureAssistantProfile(
                preferredModel: 'backend-selected-model',
                preferredReasoningEffort: 'medium',
              );
            },
            framed: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final picker = find.byKey(const Key('canonical-group-strategy-picker'));
      expect(
        find.descendant(
          of: find.byKey(const Key('canonical-group-assistant-control')),
          matching: find.text(runner.assistantDisplayName),
        ),
        findsOneWidget,
      );

      await tester.tap(picker);
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byKey(const Key('canonical-group-assistant-control')),
          matching: find.text(runner.assistantDisplayName),
        ),
        findsOneWidget,
      );
      controller.dispose();
    },
  );

  testWidgets('unconfigured and paused fixtures render muted names', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 640);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final unconfiguredRunner = _AssistantSurfaceRunner()
      ..assistantMembershipId = '';
    final unconfiguredController = ClientConversationController(
      native: unconfiguredRunner,
    );
    addTearDown(unconfiguredController.dispose);
    await unconfiguredController.initialize();
    await unconfiguredController.selectConversation('conversation:group');

    await tester.pumpWidget(
      _groupApp(
        CanonicalGroupConversationPaneFixture(
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
        of: find.byKey(const Key('canonical-group-assistant-control')),
        matching: find.text('Configure your Assistant'),
      ),
      findsOneWidget,
    );
    expect(_nameColor(tester, 'unconfigured'), colors.textMuted);

    // Paused: configured assistant, toggle tapped off.
    final runner = _AssistantSurfaceRunner();
    final controller = ClientConversationController(native: runner);
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.selectConversation('conversation:group');

    await tester.pumpWidget(
      _groupApp(
        CanonicalGroupConversationPaneFixture(
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
        of: find.byKey(const Key('canonical-group-assistant-control')),
        matching: find.text(runner.assistantDisplayName),
      ),
      findsOneWidget,
    );
    expect(_nameColor(tester, 'paused'), colors.textMuted);
    unconfiguredController.dispose();
    controller.dispose();
  });

  testWidgets(
    'working fixture keeps the assistant name and readable active text',
    (tester) async {
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
      final controller = ClientConversationController(native: runner);
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.selectConversation('conversation:group');
      await tester.pumpWidget(
        _groupApp(
          CanonicalGroupConversationPaneFixture(
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
      await tester.tap(
        find.byKey(const Key('agent-conversation-composer-send')),
      );
      await tester.pump();
      await tester.pump();

      final picker = find.byKey(const Key('canonical-group-strategy-picker'));
      final colors = tester.element(picker).licoColors;
      expect(
        find.descendant(
          of: find.byKey(const Key('canonical-group-assistant-control')),
          matching: find.text(runner.assistantDisplayName),
        ),
        findsOneWidget,
      );
      expect(_nameColor(tester, 'working'), colors.text);
      controller.dispose();
    },
  );

  testWidgets(
    'coordinating fixture keeps the assistant name and working state',
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
      final controller = ClientConversationController(native: runner);
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.selectConversation('conversation:group');

      await tester.pumpWidget(
        _groupApp(
          CanonicalGroupConversationPaneFixture(
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
      expect(
        find.descendant(
          of: find.byKey(const Key('canonical-group-assistant-control')),
          matching: find.text(runner.assistantDisplayName),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('canonical-group-assistant-status-working')),
        findsOneWidget,
      );
      controller.dispose();
    },
  );

  testWidgets('waiting fixture keeps the identity label with waiting accent', (
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
    final controller = ClientConversationController(native: runner);
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.selectConversation('conversation:group');

    await tester.pumpWidget(
      _groupApp(
        CanonicalGroupConversationPaneFixture(
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
        of: find.byKey(const Key('canonical-group-assistant-control')),
        matching: find.text(runner.assistantDisplayName),
      ),
      findsOneWidget,
    );
    expect(_nameColor(tester, 'waiting'), colors.accent);
    controller.dispose();
  });

  testWidgets('usage-limit failure keeps identity and shows safe recovery', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 640);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final runner = _AssistantSurfaceRunner();
    final controller = ClientConversationController(native: runner);
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.selectConversation('conversation:group');

    await tester.pumpWidget(
      _groupApp(
        CanonicalGroupConversationPaneFixture(
          controller: controller,
          targets: [_target('codex', 'Codex')],
          onCopyText: (_) async {},
          framed: false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    controller.surfaceFailure(
      'turn/completed',
      'codex_usage_limit_exceeded',
      component: 'native_cli',
      retryable: false,
      recovery: 'select_available_model_or_wait_for_quota_reset',
    );
    await tester.pumpAndSettle();

    final picker = find.byKey(const Key('canonical-group-strategy-picker'));
    final colors = tester.element(picker).licoColors;
    expect(
      find.descendant(
        of: find.byKey(const Key('canonical-group-assistant-control')),
        matching: find.text(runner.assistantDisplayName),
      ),
      findsOneWidget,
    );
    expect(_nameColor(tester, 'failure'), colors.error);
    expect(find.byKey(const Key('canonical-group-failure')), findsOneWidget);
    expect(
      find.textContaining('Codex model usage limit reached'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Choose another available model'),
      findsOneWidget,
    );
    controller.dispose();
  });

  for (final reduceMotion in [true, false]) {
    testWidgets(
      'plus menu floats exactly above the button, expands on hover, and dismisses outside (reduceMotion=$reduceMotion)',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(900, 640);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);

        final runner = _AssistantSurfaceRunner();
        final controller = ClientConversationController(native: runner);
        addTearDown(controller.dispose);
        await controller.initialize();
        await controller.selectConversation('conversation:group');

        await tester.pumpWidget(
          _groupApp(
            CanonicalGroupConversationPaneFixture(
              controller: controller,
              targets: [_target('codex', 'Codex')],
              onCopyText: (_) async {},
              framed: false,
              reduceMotion: reduceMotion,
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        final button = find.byKey(
          const Key('canonical-group-assistant-actions'),
        );
        final field = find.byKey(
          const Key('agent-conversation-composer-field'),
        );
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
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

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
        final archive = find.byKey(const Key('canonical-group-action-archive'));
        expect(attachments, findsOneWidget);
        expect(archive, findsOneWidget);
        expect(
          find.byKey(const Key('canonical-group-action-discard-images')),
          findsNothing,
        );
        // Attachments is nearest the button; archive is above it.
        expect(
          tester.getRect(attachments).bottom,
          greaterThan(tester.getRect(archive).bottom),
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
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(menu, findsNothing);
        expect(tester.getRect(field), fieldRect);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        controller.dispose();
      },
    );
  }

  testWidgets('archive action confirms then archives the group and reopens', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 640);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final runner = _AssistantSurfaceRunner();
    final controller = ClientConversationController(native: runner);
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.selectConversation('conversation:group');
    final originalMembershipId = runner.assistantMembershipId;
    final originalAgentId = runner.assistantAgentId;

    await tester.pumpWidget(
      _groupApp(
        CanonicalGroupConversationPaneFixture(
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
    await tester.tap(find.byKey(const Key('canonical-group-action-archive')));
    await tester.pumpAndSettle();
    expect(find.text('Archive this group conversation?'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(
      runner.requests.where(
        (request) => request['action'] == 'conversation.archive',
      ),
      isEmpty,
    );

    await tester.tap(
      find.byKey(const Key('canonical-group-assistant-actions-trigger')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('canonical-group-action-archive')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('canonical-group-archive-confirm')));
    await tester.pumpAndSettle();

    final archived = runner.requests.singleWhere(
      (request) => request['action'] == 'conversation.archive',
    );
    expect(archived['conversationId'], 'conversation:group');
    expect(archived['archived'], isTrue);
    expect(archived['reopen'], isTrue);
    // The unified mechanism never churns memberships on screen.
    expect(
      runner.requests.where(
        (request) =>
            request['action'] == 'conversation.membership.leave' ||
            request['action'] == 'conversation.membership.add',
      ),
      isEmpty,
    );

    // The pane lands on the fresh successor: new conversation id, same agent.
    expect(controller.selectedConversationId, 'conversation:successor');
    final reopened = controller.selectedConversation;
    expect(reopened, isNotNull);
    expect(reopened!.id, 'conversation:successor');
    expect(reopened.assistantMembership?.principal.agentId, originalAgentId);
    expect(reopened.assistantMembership?.id, isNot(originalMembershipId));
    expect(controller.failureCode, isEmpty);
    expect(
      find.byKey(const Key('canonical-group-conversation-pane')),
      findsOneWidget,
    );
    expect(find.text('New conversation started'), findsOneWidget);
    controller.dispose();
  });

  testWidgets(
    'typed slash-new in the group composer runs the same archive flow after confirmation and never posts',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 640);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final runner = _AssistantSurfaceRunner();
      final originalAgentId = runner.assistantAgentId;
      final controller = ClientConversationController(native: runner);
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.selectConversation('conversation:group');

      await tester.pumpWidget(
        _groupApp(
          CanonicalGroupConversationPaneFixture(
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
      await tester.tap(
        find.byKey(const Key('canonical-group-archive-confirm')),
      );
      await tester.pumpAndSettle();

      final archived = runner.requests.singleWhere(
        (request) => request['action'] == 'conversation.archive',
      );
      expect(archived['reopen'], isTrue);
      expect(
        runner.requests.where(
          (request) =>
              request['action'] == 'conversation.membership.leave' ||
              request['action'] == 'conversation.membership.add',
        ),
        isEmpty,
      );
      expect(controller.selectedConversationId, 'conversation:successor');
      expect(
        controller.selectedConversation?.assistantMembership?.principal.agentId,
        originalAgentId,
      );
      controller.dispose();
    },
  );

  testWidgets('busy assistant refuses the archive flow while a turn is live', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 640);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final runner = _AssistantSurfaceRunner();
    runner
      ..postTurns = [
        {
          'turnHandle': 'dispatch:live',
          'conversationId': 'conversation:group',
          'membershipId': runner.assistantMembershipId,
          'agent': runner.assistantAgentId,
        },
      ]
      ..dispatchPending = true;
    final persistent = _PersistentGateway();
    addTearDown(persistent.dispose);
    final controller = ClientConversationController(native: runner);
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.selectConversation('conversation:group');

    await tester.pumpWidget(
      _groupApp(
        CanonicalGroupConversationPaneFixture(
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
    await tester.tap(find.byKey(const Key('canonical-group-action-archive')));
    await tester.pump();

    expect(
      runner.requests.where(
        (request) =>
            request['action'] == 'conversation.membership.leave' ||
            request['action'] == 'conversation.membership.add' ||
            request['action'] == 'conversation.archive',
      ),
      isEmpty,
    );
    expect(controller.failureCode, 'conversation_clear_blocked');
    expect(find.byKey(const Key('canonical-group-failure')), findsOneWidget);
    expect(runner.assistantMembershipId, 'membership:codex');
    controller.dispose();
  });

  testWidgets(
    'staged images render as a pending draft and post with the shared attachment shape',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 640);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final runner = _AssistantSurfaceRunner();
      final controller = ClientConversationController(native: runner);
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.selectConversation('conversation:group');

      var staged = <ConversationAttachment>[];
      await tester.pumpWidget(
        _groupApp(
          StatefulBuilder(
            builder: (context, setState) {
              return CanonicalGroupConversationPaneFixture(
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
      controller.dispose();
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
      final controller = ClientConversationController(native: runner);
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.selectConversation('conversation:group');

      var staged = <ConversationAttachment>[];
      await tester.pumpWidget(
        _groupApp(
          StatefulBuilder(
            builder: (context, setState) {
              return CanonicalGroupConversationPaneFixture(
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
      controller.dispose();
    },
  );

  testWidgets(
    'assistant model readout follows activation and opens the editor',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 640);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final runner = _AssistantSurfaceRunner();
      final controller = ClientConversationController(native: runner);
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.selectConversation('conversation:group');

      await tester.pumpWidget(
        _groupApp(
          CanonicalGroupConversationPaneFixture(
            controller: controller,
            targets: [_target('codex', 'Codex')],
            onCopyText: (_) async {},
            framed: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final readout = find.byKey(
        const Key('canonical-group-assistant-model-readout'),
      );
      expect(readout, findsOneWidget);
      expect(find.text('gpt-5.4'), findsOneWidget);
      expect(find.text('High'), findsOneWidget);
      expect(
        tester.getRect(readout).right,
        lessThanOrEqualTo(
          tester
              .getRect(
                find.byKey(const Key('agent-conversation-composer-send')),
              )
              .left,
        ),
      );

      // Pausing the toggle hides the readout; activating brings it back.
      await tester.tap(
        find.byKey(const Key('canonical-group-assistant-toggle')),
      );
      await tester.pump();
      expect(readout, findsNothing);
      await tester.tap(
        find.byKey(const Key('canonical-group-assistant-toggle')),
      );
      await tester.pump();
      expect(readout, findsOneWidget);

      await tester.tap(readout);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('assistant-configuration-dialog')),
        findsOneWidget,
      );
      controller.dispose();
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

Color? _nameColor(WidgetTester tester, String state) {
  final dot = find.byKey(Key('canonical-group-assistant-status-$state'));
  expect(dot, findsOneWidget);
  return tester.widget<Text>(dot).style?.color;
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
final class _AssistantSurfaceRunner implements ClientConversationNativePort {
  final List<Map<String, dynamic>> requests = [];
  final List<Map<String, dynamic>> historyEvents = [];
  int revision = 2;
  String assistantMembershipId = 'membership:codex';
  bool dispatchPending = false;
  List<Map<String, dynamic>> postTurns = const [];
  int _rotationCount = 0;
  String successorId = '';

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

  String get assistantAgentId {
    final membership = _memberships.firstWhere(
      (item) => item['id'] == assistantMembershipId,
    );
    final principal = Map<String, dynamic>.from(membership['principal'] as Map);
    return (principal['agentId'] ?? '').toString();
  }

  String get assistantDisplayName {
    final membership = _memberships.firstWhere(
      (item) => item['id'] == assistantMembershipId,
    );
    final principal = Map<String, dynamic>.from(membership['principal'] as Map);
    return (principal['displayName'] ?? '').toString();
  }

  String get assistantPreferredModel =>
      (_profiles[assistantMembershipId]?['preferredModel'] ?? '').toString();

  String get assistantPreferredReasoningEffort =>
      (_profiles[assistantMembershipId]?['preferredReasoningEffort'] ?? '')
          .toString();

  void configureAssistantProfile({
    required String preferredModel,
    required String preferredReasoningEffort,
  }) {
    final current = _profiles[assistantMembershipId] ?? const {};
    _profiles[assistantMembershipId] = {
      ...current,
      'revision': ((current['revision'] as num?)?.toInt() ?? 0) + 1,
      'preferredModel': preferredModel,
      'preferredReasoningEffort': preferredReasoningEffort,
    };
  }

  Iterable<Map<String, dynamic>> get _activeMemberships =>
      _memberships.where((membership) => membership['status'] == 'active');

  @override
  Future<Map<String, dynamic>> executeClientConversation(
    ClientConversationCommand command,
  ) async {
    final request = command.payload;
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
      case 'conversation.clear':
        final previous = assistantMembershipId;
        if (previous.isNotEmpty) {
          for (final membership in _memberships) {
            if (membership['id'] == previous) {
              membership['status'] = 'left';
              membership['leftAtUnixMs'] = 4;
            }
          }
          final rotatedId = 'membership:codex-cleared-${++_rotationCount}';
          _memberships.add(
            _membership(
              id: rotatedId,
              principalId: 'agent:codex',
              kind: 'agent',
              label: assistantDisplayName,
              agentId: assistantAgentId,
            ),
          );
          _profiles[rotatedId] = Map<String, dynamic>.from(
            _profiles[previous] ?? const <String, dynamic>{},
          );
          assistantMembershipId = rotatedId;
        }
        revision += 1;
        return {
          'ok': true,
          'result': <String, dynamic>{
            'conversationId': 'conversation:group',
            'archivedChildIds': <String>[],
            'assistantMembershipId': assistantMembershipId,
          },
        };
      case 'conversation.archive':
        revision += 1;
        if (request['reopen'] == true) {
          successorId = 'conversation:successor';
          return {
            'ok': true,
            'result': <String, dynamic>{
              'conversationId': 'conversation:group',
              'archivedChildIds': <String>[],
              'archivedNativeSessions': <Map<String, dynamic>>[],
              'successor': _successorConversation(),
            },
          };
        }
        return {
          'ok': true,
          'result': <String, dynamic>{
            'conversationId': 'conversation:group',
            'archivedChildIds': <String>[],
          },
        };
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
          if (successorId.isNotEmpty)
            {
              'id': successorId,
              'title': 'Lico',
              'archived': false,
              'pinned': false,
              'isGroup': true,
              'revision': 0,
              'updatedAtUnixMs': 5,
              'membershipCount': _activeMemberships.length,
              'eventCount': 1,
            },
          if (successorId.isEmpty || request['includeArchived'] == true)
            {
              'id': 'conversation:group',
              'title': 'Lico',
              'archived': successorId.isNotEmpty,
              'pinned': true,
              'isGroup': true,
              'revision': revision,
              'updatedAtUnixMs': 2,
              'membershipCount': _activeMemberships.length,
              'eventCount': 0,
            },
        ],
        'conversation.get' =>
          (request['conversationId'] ?? '') == successorId
              ? _successorConversation()
              : {
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
          'events': (request['conversationId'] ?? '') == successorId
              ? [_successorResetEvent()]
              : historyEvents,
          'nextCursor': null,
          'totalCount': (request['conversationId'] ?? '') == successorId
              ? 1
              : historyEvents.length,
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

  Map<String, dynamic> _successorConversation() {
    final successorMemberships = [
      for (final membership in _memberships)
        if (membership['status'] == 'active')
          <String, dynamic>{
            ...membership,
            'id': '${membership['id']}-successor',
            'conversationId': successorId,
          },
    ];
    return <String, dynamic>{
      'id': successorId,
      'title': 'Lico',
      'archived': false,
      'pinned': false,
      'isGroup': true,
      if (assistantMembershipId.isNotEmpty)
        'assistantMembershipId': '$assistantMembershipId-successor',
      'revision': 0,
      'createdAtUnixMs': 5,
      'updatedAtUnixMs': 5,
      'eventCount': 1,
      'memberships': successorMemberships,
    };
  }

  Map<String, dynamic> _successorResetEvent() => <String, dynamic>{
    'id': 'event:successor-reset',
    'conversationId': successorId,
    'sequence': 1,
    'authorMembershipId': null,
    'kind': 'conversation-reset',
    'createdAtUnixMs': 5,
    'finalized': true,
    'parts': <Map<String, dynamic>>[
      {
        'id': 'part:successor-reset',
        'eventId': 'event:successor-reset',
        'ordinal': 0,
        'kind': 'metadata',
        'content': '{"reopenedFromConversationId":"conversation:group"}',
        'createdAtUnixMs': 5,
      },
    ],
  };
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
    this.acceptOnly = false,
  }) : _active = List<Map<String, dynamic>>.unmodifiable(active) {
    _chunks = StreamController<AgentDispatchEvent>.broadcast();
  }

  final List<Map<String, dynamic>> _active;
  final bool waiting;
  final bool acceptOnly;
  void emitReply(String text) => _chunks.add(
    AgentDispatchEvent(
      kind: 'agent.message.chunk',
      payload: {
        'text': text,
        'cursor': 2,
        'lifecyclePrefix': [
          'submitted',
          'accepted',
          'processing',
          'responding',
        ],
      },
    ),
  );
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
        acceptOnly
            ? const AgentDispatchEvent(
                kind: 'agent.turn.accepted',
                payload: {
                  'lifecyclePrefix': ['submitted', 'accepted'],
                  'cursor': 1,
                },
              )
            : waiting
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
