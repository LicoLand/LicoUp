import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_log_event_row.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_message_blocks.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_timeline.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_participant_runtime_profile.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_render_adapter.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_agent_bubble.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_participant_flow.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_process_status_row.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_user_bubble_glass.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/agent_brand_icon.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

void main() {
  group('buildMessagingFlowEntries', () {
    test('groups consecutive same-author messages and breaks on long gaps', () {
      final entries = buildMessagingFlowEntries([
        _messageItem('k1', 'user', 'one', _at(10, 0)),
        _messageItem('k2', 'user', 'two', _at(10, 3)),
        _messageItem('k3', 'user', 'three', _at(10, 12)),
      ]);

      expect(entries.map((entry) => entry.runtimeType).toList(), [
        MessagingFlowDayDivider,
        MessagingFlowMessageGroup,
        MessagingFlowMessageGroup,
      ]);
      final first = entries[1] as MessagingFlowMessageGroup;
      final second = entries[2] as MessagingFlowMessageGroup;
      expect(first.authorIsUser, isTrue);
      expect(first.messages.map((message) => message.text), ['one', 'two']);
      expect(second.messages.map((message) => message.text), ['three']);
    });

    test('breaks groups on author change and on process items', () {
      final entries = buildMessagingFlowEntries([
        _messageItem('k1', 'user', 'question', _at(10, 0)),
        _processItem('p1', [_event('e1', _at(10, 1))]),
        _messageItem('k2', 'user', 'follow-up', _at(10, 2)),
        _messageItem('k3', 'assistant', 'answer', _at(10, 3)),
      ]);

      expect(entries.map((entry) => entry.runtimeType).toList(), [
        MessagingFlowDayDivider,
        MessagingFlowMessageGroup,
        MessagingFlowProcess,
        MessagingFlowMessageGroup,
        MessagingFlowMessageGroup,
      ]);
      final agentGroup = entries[4] as MessagingFlowMessageGroup;
      expect(agentGroup.authorIsUser, isFalse);
    });

    test('breaks agent groups when the participant changes', () {
      final entries = buildMessagingFlowEntries([
        _participantMessageItem(
          'k1',
          'designer',
          'Designer',
          'design',
          _at(10, 0),
        ),
        _participantMessageItem(
          'k2',
          'backend-worker',
          'Backend Worker',
          'implementation',
          _at(10, 1),
        ),
      ]);

      expect(entries.whereType<MessagingFlowMessageGroup>().length, 2);
      final groups = entries.whereType<MessagingFlowMessageGroup>().toList();
      expect(groups.first.participantLabel, 'Designer');
      expect(groups.last.participantLabel, 'Backend Worker');
    });

    test('keeps Assistant and Subagent bubbles in canonical message order', () {
      final entries = buildMessagingFlowEntries([
        _participantMessageItem(
          'assistant-1',
          'codex',
          'Assistant',
          'plan',
          _at(10, 0),
          participantRole: 'assistant',
        ),
        _participantMessageItem(
          'worker-1',
          'worker-a',
          'Worker A',
          'implementation',
          _at(10, 1),
          participantRole: 'member',
        ),
        _participantMessageItem(
          'assistant-2',
          'codex',
          'Assistant',
          'review',
          _at(10, 2),
          participantRole: 'assistant',
        ),
      ]);

      final groups = entries.whereType<MessagingFlowMessageGroup>().toList();
      expect(groups.map((group) => group.participantRole), [
        'assistant',
        'member',
        'assistant',
      ]);
      expect(groups.map((group) => group.messages.single.text), [
        'plan',
        'implementation',
        'review',
      ]);
    });

    test('marks the active process entry from its storage key', () {
      final entries = buildMessagingFlowEntries([
        _processItem('p1', [_event('e1', _at(10, 1))]),
      ], activeProcessStorageKey: 'p1');

      final process = entries.single as MessagingFlowProcess;
      expect(process.active, isTrue);
    });

    test('inserts day dividers when the local day changes', () {
      final entries = buildMessagingFlowEntries([
        _messageItem('k1', 'user', 'before', _date(2026, 7, 27, 23)),
        _messageItem('k2', 'user', 'after', _date(2026, 7, 28, 1)),
      ]);

      expect(entries.map((entry) => entry.runtimeType).toList(), [
        MessagingFlowDayDivider,
        MessagingFlowMessageGroup,
        MessagingFlowDayDivider,
        MessagingFlowMessageGroup,
      ]);
    });

    test('routes subagent cards into their own entry', () {
      final entries = buildMessagingFlowEntries([
        _messageItem('k1', 'assistant', 'delegating', _at(10, 0)),
        ConversationMessageTimelineItem(
          'k2',
          AgentConversationMessage(
            id: 'm2',
            role: 'assistant',
            text: 'subagent card',
            createdAt: _at(10, 1),
            cardType: 'subagent',
          ),
        ),
        _messageItem('k3', 'assistant', 'done', _at(10, 2)),
      ]);

      expect(entries.map((entry) => entry.runtimeType).toList(), [
        MessagingFlowDayDivider,
        MessagingFlowMessageGroup,
        MessagingFlowSubagent,
        MessagingFlowMessageGroup,
      ]);
    });
  });

  group('patchMessagingFlowStreamedMessages', () {
    test(
      'patches only the newest group and preserves older entry identity',
      () {
        // Newest-first timeline order, matching the message-list cache.
        final previousItems = [
          _messageItem('k-new', 'assistant', 'partial', _at(10, 2)),
          _messageItem('k-mid', 'user', 'question', _at(10, 1)),
          _messageItem('k-old', 'assistant', 'earlier answer', _at(10, 0)),
        ];
        final base = buildMessagingFlowEntries(
          previousItems.reversed.toList(),
        ).reversed.toList();

        final revised = ConversationMessageTimelineItem(
          'k-new',
          AgentConversationMessage(
            id: 'k-new',
            role: 'assistant',
            text: 'partial plus more',
            createdAt: _at(10, 2),
          ),
        );
        final nextItems = [revised, previousItems[1], previousItems[2]];

        final patched = patchMessagingFlowStreamedMessages(
          previousItems: previousItems,
          nextItems: nextItems,
          previousEntries: base,
        );

        expect(patched, isNotNull);
        expect(patched!.length, base.length);
        // The newest group is the only replaced entry; every older entry keeps
        // object identity so the list view does not rebuild them.
        for (var index = 1; index < patched.length; index += 1) {
          expect(identical(patched[index], base[index]), isTrue);
        }
        final newest = patched.first as MessagingFlowMessageGroup;
        expect(newest.messages.last.text, 'partial plus more');
        // The day divider and older groups were never re-derived.
        expect(identical(patched.first, base.first), isFalse);
      },
    );

    test('patches a mid-list streamed text revision (multi-agent turns)', () {
      // With two concurrent turns, the changed reply is not the newest item;
      // the patch must still apply because only text advanced.
      final previousItems = [
        _messageItem('k-b', 'assistant', 'partial B', _at(10, 2)),
        _messageItem('k-a', 'assistant', 'partial A', _at(10, 1)),
      ];
      final base = buildMessagingFlowEntries(
        previousItems.reversed.toList(),
      ).reversed.toList();

      final nextItems = [
        previousItems[0],
        ConversationMessageTimelineItem(
          'k-a',
          AgentConversationMessage(
            id: 'k-a',
            role: 'assistant',
            text: 'partial A and more',
            createdAt: _at(10, 1),
          ),
        ),
      ];

      final patched = patchMessagingFlowStreamedMessages(
        previousItems: previousItems,
        nextItems: nextItems,
        previousEntries: base,
      );

      expect(patched, isNotNull);
      expect(patched!.length, base.length);
      final updated = patched.whereType<MessagingFlowMessageGroup>().firstWhere(
        (group) => group.messages.any((m) => m.id == 'k-a'),
      );
      expect(
        updated.messages.firstWhere((m) => m.id == 'k-a').text,
        'partial A and more',
      );
    });

    test('rejects structural changes so the caller rebuilds', () {
      final previousItems = [
        _messageItem('k-new', 'assistant', 'partial', _at(10, 2)),
        _messageItem('k-old', 'user', 'question', _at(10, 1)),
      ];
      final base = buildMessagingFlowEntries(
        previousItems.reversed.toList(),
      ).reversed.toList();

      // Length change (a new message arrived) is structural.
      final grown = [
        _messageItem('k-newest', 'user', 'follow-up', _at(10, 3)),
        ...previousItems,
      ];
      expect(
        patchMessagingFlowStreamedMessages(
          previousItems: previousItems,
          nextItems: grown,
          previousEntries: base,
        ),
        isNull,
      );

      // A role change at the same key is structural even though the list
      // length and storage keys stay the same.
      final roleChanged = [
        previousItems[0],
        ConversationMessageTimelineItem(
          'k-old',
          AgentConversationMessage(
            id: 'k-old',
            role: 'assistant',
            text: 'question',
            createdAt: _at(10, 1),
          ),
        ),
      ];
      expect(
        patchMessagingFlowStreamedMessages(
          previousItems: previousItems,
          nextItems: roleChanged,
          previousEntries: base,
        ),
        isNull,
      );
    });
  });

  testWidgets('flow renders group headers, agent badge, and day dividers', (
    tester,
  ) async {
    final now = DateTime.now();
    final todayAt = DateTime(now.year, now.month, now.day, 9);
    final yesterdayAt = DateTime(now.year, now.month, now.day - 1, 22);
    final chronological = [
      _messageItem('k1', 'user', 'old request', yesterdayAt.toIso8601String()),
      _messageItem(
        'k2',
        'assistant',
        'old answer',
        yesterdayAt.toIso8601String(),
      ),
      _messageItem('k3', 'assistant', 'new answer', todayAt.toIso8601String()),
      _messageItem('k4', 'user', 'new request', todayAt.toIso8601String()),
    ];
    await _pumpFlow(tester, chronological.reversed.toList());

    expect(find.text('You'), findsNWidgets(2));
    expect(find.text('Codex'), findsNWidgets(2));
    expect(find.byKey(const Key('messaging-agent-badge')), findsNWidgets(2));
    expect(find.text('AGENT'), findsNWidgets(2));
    expect(find.byType(AgentBrandIcon), findsNWidgets(2));
    expect(find.byKey(const Key('messaging-user-avatar')), findsNWidgets(2));
    expect(find.byIcon(Icons.person_outline_rounded), findsNWidgets(2));
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Yesterday'), findsOneWidget);
    expect(find.text('old request', findRichText: true), findsOneWidget);
    expect(find.text('new answer', findRichText: true), findsOneWidget);
    expect(find.byKey(const Key('messaging-message-bubble')), findsNWidgets(4));
    expect(
      find.byKey(const Key('messaging-message-hover-timestamp')),
      findsNWidgets(4),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('group headers omit timestamps', (tester) async {
    final messageAt = DateTime(2026, 7, 20, 18, 58);
    final chronological = [
      _messageItem(
        'k1',
        'assistant',
        'agent reply',
        messageAt.toIso8601String(),
      ),
      _messageItem('k2', 'user', 'user request', messageAt.toIso8601String()),
    ];
    await _pumpFlow(tester, chronological.reversed.toList());

    // Timestamps live in reserved hover slots (opacity 0), never in headers.
    final timestamps = find.byKey(
      const Key('messaging-message-hover-timestamp'),
    );
    expect(timestamps, findsNWidgets(2));
    for (final element in timestamps.evaluate()) {
      final opacity = element
          .findAncestorWidgetOfExactType<AnimatedOpacity>()
          ?.opacity;
      expect(opacity, 0);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Assistant bubble is distinct while Subagent shows model and reasoning effort',
    (tester) async {
      final chronological = [
        _participantMessageItem(
          'assistant',
          'codex',
          'Assistant',
          'assistant answer',
          _at(10, 0),
          participantRole: 'assistant',
        ),
        _participantMessageItem(
          'worker',
          'worker-a',
          'Worker A',
          'subagent answer',
          _at(10, 1),
          participantRole: 'member',
        ),
      ];
      await _pumpFlow(
        tester,
        chronological.reversed.toList(),
        participantTargets: [
          _flowTarget('codex', 'Codex'),
          _flowTarget('worker-a', 'Worker A'),
        ],
        participantRuntimeProfiles: const {
          'worker-a': AgentParticipantRuntimeProfile(
            model: 'worker-model',
            reasoningEffort: 'high',
          ),
        },
      );

      expect(find.text('ASSISTANT'), findsOneWidget);
      expect(find.text('SUBAGENT'), findsOneWidget);
      expect(
        find.byKey(const Key('messaging-assistant-avatar')),
        findsOneWidget,
      );
      expect(find.text('worker-model · High'), findsOneWidget);

      // Agent-side bubbles share one edge-lit veil: light on the rim, never
      // a solid accentSurface fill.
      final assistantBubble = tester.widget<MessagingAgentBubble>(
        find
            .ancestor(
              of: find.text('assistant answer', findRichText: true),
              matching: find.byType(MessagingAgentBubble),
            )
            .first,
      );
      final subagentBubble = tester.widget<MessagingAgentBubble>(
        find
            .ancestor(
              of: find.text('subagent answer', findRichText: true),
              matching: find.byType(MessagingAgentBubble),
            )
            .first,
      );
      expect(assistantBubble.hovered, isFalse);
      expect(subagentBubble.hovered, isFalse);

      BoxDecoration bubbleDecoration(MessagingAgentBubble bubble) {
        final animated = tester.widget<AnimatedContainer>(
          find.descendant(
            of: find.byWidget(bubble),
            matching: find.byType(AnimatedContainer),
          ),
        );
        return animated.decoration! as BoxDecoration;
      }

      final themeColors = Theme.of(
        tester.element(find.byWidget(assistantBubble)),
      ).extension<LicoThemeColors>()!;
      final expectedVeil = MessagingDesktopMetrics.agentBubbleVeilFill(
        isDark: themeColors.isDark,
      );
      for (final bubble in [assistantBubble, subagentBubble]) {
        final decoration = bubbleDecoration(bubble);
        expect(decoration.color, expectedVeil);
        expect(decoration.color, isNot(equals(themeColors.accentSurface)));
        expect(decoration.gradient, isNull);
      }
    },
  );

  testWidgets(
    'hover reveals per-message timestamp outside bubble bottom-right',
    (tester) async {
      final messageAt = DateTime(2026, 7, 20, 18, 58);
      final chronological = [
        _messageItem(
          'k1',
          'assistant',
          'agent reply',
          messageAt.toIso8601String(),
        ),
        _messageItem('k2', 'user', 'user request', messageAt.toIso8601String()),
      ];
      await _pumpFlow(tester, chronological.reversed.toList());

      final formattedTime = MaterialLocalizations.of(
        tester.element(find.byType(Scaffold)),
      ).formatTimeOfDay(TimeOfDay.fromDateTime(messageAt));

      final agentBubble = find.ancestor(
        of: find.text('agent reply', findRichText: true),
        matching: find.byKey(const Key('messaging-message-bubble')),
      );
      final agentRow = find.ancestor(
        of: agentBubble,
        matching: find.byType(MouseRegion),
      );
      final agentTimestamp = find.descendant(
        of: agentRow,
        matching: find.byKey(const Key('messaging-message-hover-timestamp')),
      );
      final heightBeforeHover = tester.getSize(agentRow).height;

      expect(
        find.byKey(const Key('messaging-message-hover-timestamp')),
        findsNWidgets(2),
      );
      expect(
        tester
            .widget<AnimatedOpacity>(
              find.ancestor(
                of: agentTimestamp,
                matching: find.byType(AnimatedOpacity),
              ),
            )
            .opacity,
        0,
      );
      expect(find.text(formattedTime), findsNWidgets(2));

      final hoverGesture = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await hoverGesture.moveTo(tester.getCenter(agentBubble));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));

      expect(
        tester
            .widget<AnimatedOpacity>(
              find.ancestor(
                of: agentTimestamp,
                matching: find.byType(AnimatedOpacity),
              ),
            )
            .opacity,
        1,
      );
      expect(find.text(formattedTime), findsNWidgets(2));
      expect(tester.getSize(agentRow).height, closeTo(heightBeforeHover, 0.1));

      final bubbleBox = tester.renderObject<RenderBox>(agentBubble);
      final timestampBox = tester.renderObject<RenderBox>(agentTimestamp);
      final bubbleBottomRight = bubbleBox.localToGlobal(
        Offset(bubbleBox.size.width, bubbleBox.size.height),
      );
      final timestampBottomRight = timestampBox.localToGlobal(
        Offset(timestampBox.size.width, timestampBox.size.height),
      );
      expect(timestampBox.size.width, lessThanOrEqualTo(bubbleBox.size.width));
      expect(timestampBottomRight.dx, closeTo(bubbleBottomRight.dx, 1));
      expect(timestampBottomRight.dy, greaterThan(bubbleBottomRight.dy));

      await hoverGesture.moveTo(const Offset(-1, -1));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(
        find.byKey(const Key('messaging-message-hover-timestamp')),
        findsNWidgets(2),
      );
      expect(tester.getSize(agentRow).height, closeTo(heightBeforeHover, 0.1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'hover timestamp parses native epoch createdAt without layout shift',
    (tester) async {
      final messageAt = DateTime.utc(2026, 3, 13, 12, 40);
      final chronological = [
        _messageItem(
          'k1',
          'assistant',
          'epoch reply',
          '${messageAt.millisecondsSinceEpoch}',
        ),
      ];
      await _pumpFlow(tester, chronological.reversed.toList());

      final formattedTime = MaterialLocalizations.of(
        tester.element(find.byType(Scaffold)),
      ).formatTimeOfDay(TimeOfDay.fromDateTime(messageAt.toLocal()));

      final bubble = find.byKey(const Key('messaging-message-bubble'));
      final row = find.ancestor(of: bubble, matching: find.byType(MouseRegion));
      final heightBeforeHover = tester.getSize(row).height;
      final hoverTimestamp = find.byKey(
        const Key('messaging-message-hover-timestamp'),
      );
      expect(hoverTimestamp, findsOneWidget);
      expect(find.text(formattedTime), findsOneWidget);

      final hoverGesture = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await hoverGesture.moveTo(tester.getCenter(bubble));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));

      expect(
        tester
            .widget<AnimatedOpacity>(
              find.ancestor(
                of: hoverTimestamp,
                matching: find.byType(AnimatedOpacity),
              ),
            )
            .opacity,
        1,
      );
      expect(tester.getSize(row).height, closeTo(heightBeforeHover, 0.1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('user message groups align to the right of the transcript', (
    tester,
  ) async {
    final now = DateTime.now();
    final todayAt = DateTime(now.year, now.month, now.day, 9);
    final chronological = [
      _messageItem('k1', 'assistant', 'agent reply', todayAt.toIso8601String()),
      _messageItem('k2', 'user', 'user request', todayAt.toIso8601String()),
    ];
    await _pumpFlow(tester, chronological.reversed.toList());

    expect(
      find.byKey(const Key('messaging-user-message-group')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('messaging-agent-message-group')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('messaging-user-avatar')), findsOneWidget);
    expect(find.byIcon(Icons.person_outline_rounded), findsOneWidget);

    final agentGroupFinder = find.byKey(
      const Key('messaging-agent-message-group'),
    );
    final agentBrandIcon = tester.widget<AgentBrandIcon>(
      find.descendant(
        of: agentGroupFinder,
        matching: find.byType(AgentBrandIcon),
      ),
    );
    expect(agentBrandIcon.target.target, 'codex');

    final userGroup = tester.renderObject<RenderBox>(
      find.byKey(const Key('messaging-user-message-group')),
    );
    final agentGroup = tester.renderObject<RenderBox>(
      find.byKey(const Key('messaging-agent-message-group')),
    );
    final userBubble = tester.renderObject<RenderBox>(
      find.ancestor(
        of: find.text('user request', findRichText: true),
        matching: find.byKey(const Key('messaging-message-bubble')),
      ),
    );
    final agentBubble = tester.renderObject<RenderBox>(
      find.ancestor(
        of: find.text('agent reply', findRichText: true),
        matching: find.byKey(const Key('messaging-message-bubble')),
      ),
    );

    expect(userGroup.size.width, agentGroup.size.width);
    expect(
      userBubble.localToGlobal(Offset.zero).dx + userBubble.size.width,
      closeTo(
        userGroup.localToGlobal(Offset.zero).dx + userGroup.size.width,
        1,
      ),
    );
    expect(
      agentBubble.localToGlobal(Offset.zero).dx,
      closeTo(agentGroup.localToGlobal(Offset.zero).dx, 1),
    );
    expect(
      userBubble.localToGlobal(Offset.zero).dx,
      greaterThan(agentBubble.localToGlobal(Offset.zero).dx),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('user bubbles use frosted glass instead of solid brandSurface', (
    tester,
  ) async {
    final now = DateTime.now();
    final todayAt = DateTime(now.year, now.month, now.day, 9);
    final chronological = [
      _messageItem('k1', 'user', 'user request', todayAt.toIso8601String()),
    ];
    await _pumpFlow(tester, chronological.reversed.toList());

    expect(find.byType(MessagingUserBubbleGlass), findsOneWidget);
    final themeColors = buildLicoTheme(
      platformBrightness: Brightness.dark,
    ).extension<LicoThemeColors>()!;
    final animated = tester.widget<AnimatedContainer>(
      find.descendant(
        of: find.byType(MessagingUserBubbleGlass),
        matching: find.byType(AnimatedContainer),
      ),
    );
    final decoration = animated.decoration! as BoxDecoration;
    expect(decoration.color, Colors.transparent);
    expect(decoration.gradient, isNull);
    expect(decoration.color, isNot(themeColors.brandSurface));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'streamed newest message text updates in place without losing order',
    (tester) async {
      final first = _messageItem('k1', 'assistant', 'he', _at(10, 0, 0));
      final second = _messageItem('k2', 'user', 'question', _at(10, 0, 1));
      // Newest first: the streamed assistant reply is the first item (index 0).
      final newestFirst = [first, second];
      await _pumpFlow(tester, newestFirst);
      expect(find.text('he'), findsOneWidget);

      // A streamed update replaces the newest item content (same identity key,
      // new message object, same list identity). The flow must re-derive the
      // newest entry and render the new text.
      final updated = ConversationMessageTimelineItem(
        'k1',
        AgentConversationMessage(
          id: 'k1',
          role: 'assistant',
          text: 'hello world',
          createdAt: '2026-08-24T02:00:00.000Z',
          stableIdentity: 'k1',
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          supportedLocales: LicoStrings.supportedLocales,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          theme: buildLicoTheme(platformBrightness: Brightness.dark),
          home: Scaffold(
            body: SizedBox(
              width: 800,
              height: 600,
              child: MessagingParticipantFlow(
                items: [updated, second],
                adapter: AgentRenderAdapter.fallback(),
                target: _flowTarget('codex', 'Codex'),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('hello world'), findsOneWidget);
      expect(find.text('he'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('long transcripts keep every lazy list row', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final chronological = [
      for (var index = 0; index < 120; index++)
        _messageItem(
          'k$index',
          index.isEven ? 'user' : 'assistant',
          'message-$index',
          _at(1, 0, index),
        ),
    ];
    await _pumpFlow(
      tester,
      chronological.reversed.toList(),
      scrollController: controller,
    );

    int listItemCount() =>
        (tester.widget<ListView>(find.byType(ListView)).childrenDelegate
                as SliverChildBuilderDelegate)
            .estimatedChildCount ??
        0;

    // Every row belongs to the lazy delegate, while only the viewport builds.
    expect(find.text('message-119', findRichText: true), findsOneWidget);
    expect(listItemCount(), 121);
    expect(find.text('message-0', findRichText: true), findsNothing);

    // Scrolling builds the oldest retained row without changing the delegate.
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(listItemCount(), 121);
    expect(find.text('message-0', findRichText: true), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('oldest edge requests one native message page', (tester) async {
    final pending = Completer<void>();
    var calls = 0;
    final chronological = [
      for (var index = 0; index < 80; index++)
        _messageItem(
          'page-$index',
          index.isEven ? 'user' : 'assistant',
          'page-message-$index',
          _at(1, 0, index),
        ),
    ];
    await _pumpFlow(
      tester,
      chronological.reversed.toList(),
      hasEarlier: true,
      onLoadEarlier: () {
        calls += 1;
        return pending.future;
      },
    );

    await tester.drag(find.byType(ListView), const Offset(0, 12000));
    await tester.pump();
    expect(calls, 1);
    pending.complete();
    await tester.pump();
  });

  testWidgets(
    'scroll-to-latest appears when not at bottom and tap jumps to latest',
    (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      final chronological = [
        for (var index = 0; index < 40; index++)
          _messageItem(
            'k$index',
            index.isEven ? 'user' : 'assistant',
            'message-$index',
            _at(1, 0, index),
          ),
      ];
      await _pumpFlow(
        tester,
        chronological.reversed.toList(),
        scrollController: controller,
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('conversation-scroll-to-latest')),
        findsNothing,
      );
      expect(controller.hasClients, isTrue);
      expect(controller.position.maxScrollExtent, greaterThan(48));

      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pump();

      expect(
        find.byKey(const Key('conversation-scroll-to-latest')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('conversation-scroll-to-latest')));
      await tester.pump();

      expect(controller.offset, 0);
      expect(
        find.byKey(const Key('conversation-scroll-to-latest')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('subagent cards in the lazy history appear on scroll', (
    tester,
  ) async {
    final chronological = <ConversationTimelineItem>[
      for (var index = 0; index < 5; index++)
        _messageItem(
          'k$index',
          index.isEven ? 'user' : 'assistant',
          'message-$index',
          _at(1, 0, index),
        ),
      // A delegated card sits near the start, outside the initial viewport.
      ConversationMessageTimelineItem(
        'k-card',
        AgentConversationMessage(
          id: 'm-card',
          role: 'assistant',
          text: 'delegated work',
          createdAt: _at(1, 0, 5),
          cardType: 'subagent',
          cardTitle: 'Discovery worker',
        ),
      ),
      for (var index = 6; index < 100; index++)
        _messageItem(
          'k$index',
          index.isEven ? 'user' : 'assistant',
          'message-$index',
          _at(1, 0, index),
        ),
    ];
    await _pumpFlow(tester, chronological.reversed.toList());

    // The card is outside the initial viewport: not built yet.
    expect(find.byType(AgentConversationSubagentCardBlock), findsNothing);

    // Scrolling to the top builds it from the complete lazy delegate.
    await tester.drag(find.byType(ListView), const Offset(0, 12000));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, 12000));
    await tester.pumpAndSettle();
    int listItemCount() =>
        (tester.widget<ListView>(find.byType(ListView)).childrenDelegate
                as SliverChildBuilderDelegate)
            .estimatedChildCount ??
        0;
    // The full history is loaded (99 message groups + day divider + card)
    // and the card row is part of the flow projection.
    expect(listItemCount(), 101);
    final entries = buildMessagingFlowEntries(chronological.reversed.toList());
    expect(
      entries.whereType<MessagingFlowSubagent>().length,
      1,
      reason: 'the delegated card must stay in the flow projection',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('flow renders process runs as inline status rows', (
    tester,
  ) async {
    final chronological = [
      _messageItem('k1', 'user', 'run it', _at(10, 0)),
      _processItem('p1', [
        _event('e1', _at(10, 1)),
        _event('e2', _at(10, 1, 12)),
      ]),
      _messageItem('k2', 'assistant', 'done', _at(10, 2)),
    ];
    await _pumpFlow(tester, chronological.reversed.toList());

    expect(find.byType(MessagingProcessStatusRow), findsOneWidget);
    expect(find.textContaining('Worked for 12s'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('process status rows span and center in transcript column', (
    tester,
  ) async {
    final chronological = [
      _messageItem('k1', 'user', 'run it', _at(10, 0)),
      _processItem('p1', [
        _lifecycleEvent(
          'completed',
          observed: 'submitted,accepted,processing,responding,completed',
        ),
        _event('e1', _at(10, 1)),
        _event('e2', _at(10, 1, 12)),
      ]),
      _messageItem('k2', 'assistant', 'done', _at(10, 2)),
    ];
    await _pumpFlow(tester, chronological.reversed.toList());

    final processCard = tester.renderObject<RenderBox>(
      find.byKey(const Key('messaging-process-status-idle')),
    );
    final agentBubble = tester.renderObject<RenderBox>(
      find.ancestor(
        of: find.text('done', findRichText: true),
        matching: find.byKey(const Key('messaging-message-bubble')),
      ),
    );
    final agentGroup = tester.renderObject<RenderBox>(
      find.byKey(const Key('messaging-agent-message-group')),
    );

    expect(processCard.size.width, closeTo(agentGroup.size.width, 1));
    expect(processCard.size.width, greaterThan(agentBubble.size.width));
    final processCenter = processCard
        .localToGlobal(Offset(processCard.size.width / 2, 0))
        .dx;
    final groupCenter = agentGroup
        .localToGlobal(Offset(agentGroup.size.width / 2, 0))
        .dx;
    expect(processCenter, closeTo(groupCenter, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('runtime log cards span and center in transcript column', (
    tester,
  ) async {
    final chronological = [
      _messageItem('k1', 'user', 'run it', _at(10, 0)),
      ConversationLogTimelineItem('log-1', [
        AgentConversationMessage(
          id: 'log-event',
          role: 'event',
          text: 'synthetic runtime detail',
          createdAt: _at(10, 1),
          cardType: 'provider-event',
        ),
      ]),
      _messageItem('k2', 'assistant', 'done', _at(10, 2)),
    ];
    await _pumpFlow(tester, chronological.reversed.toList());

    expect(find.byType(ConversationLogEventRow), findsOneWidget);
    final logCard = tester.renderObject<RenderBox>(
      find.byKey(const Key('conversation-runtime-log-card')),
    );
    final agentGroup = tester.renderObject<RenderBox>(
      find.byKey(const Key('messaging-agent-message-group')),
    );

    expect(logCard.size.width, closeTo(agentGroup.size.width, 1));
    final logCenter = logCard
        .localToGlobal(Offset(logCard.size.width / 2, 0))
        .dx;
    final groupCenter = agentGroup
        .localToGlobal(Offset(agentGroup.size.width / 2, 0))
        .dx;
    expect(logCenter, closeTo(groupCenter, 1));
    expect(tester.takeException(), isNull);
  });
}

AgentConversationMessage _lifecycleEvent(
  String stage, {
  required String observed,
}) {
  return AgentConversationMessage(
    id: 'lifecycle',
    role: 'event',
    text: stage,
    createdAt: _at(10, 1, 0),
    cardType: 'lifecycle',
    cardTitle: 'lifecycle.$stage',
    cardSubtitle: observed,
  );
}

ConversationMessageTimelineItem _participantMessageItem(
  String key,
  String participantAgentId,
  String participantLabel,
  String text,
  String createdAt, {
  String? participantRole,
}) {
  return ConversationMessageTimelineItem(
    key,
    AgentConversationMessage(
      id: key,
      role: 'assistant',
      text: text,
      createdAt: createdAt,
      participantAgentId: participantAgentId,
      participantLabel: participantLabel,
      participantRole: participantRole ?? participantAgentId,
    ),
  );
}

String _at(int hour, int minute, [int second = 0]) =>
    DateTime(2026, 7, 20, hour, minute, second).toIso8601String();

String _date(int year, int month, int day, int hour) =>
    DateTime(year, month, day, hour).toIso8601String();

ConversationMessageTimelineItem _messageItem(
  String key,
  String role,
  String text,
  String createdAt,
) {
  return ConversationMessageTimelineItem(
    key,
    AgentConversationMessage(
      id: key,
      role: role,
      text: text,
      createdAt: createdAt,
    ),
  );
}

AgentConversationMessage _event(String id, String createdAt) {
  return AgentConversationMessage(
    id: id,
    role: 'tool',
    text: 'ran tool',
    createdAt: createdAt,
  );
}

ConversationProcessTimelineItem _processItem(
  String key,
  List<AgentConversationMessage> events,
) {
  return ConversationProcessTimelineItem(key, events);
}

Future<void> _pumpFlow(
  WidgetTester tester,
  List<ConversationTimelineItem> newestFirst, {
  ScrollController? scrollController,
  List<TargetCandidate> participantTargets = const [],
  Map<String, AgentParticipantRuntimeProfile> participantRuntimeProfiles =
      const {},
  bool hasEarlier = false,
  Future<void> Function()? onLoadEarlier,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      supportedLocales: LicoStrings.supportedLocales,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      theme: buildLicoTheme(platformBrightness: Brightness.dark),
      home: Scaffold(
        body: SizedBox(
          width: 800,
          height: 600,
          child: MessagingParticipantFlow(
            items: newestFirst,
            adapter: AgentRenderAdapter.fallback(),
            target: TargetCandidate(
              target: 'codex',
              label: 'Codex',
              kind: 'cli',
              status: 'detected',
              configured: true,
              confidence: 1,
              adapterStatus: 'implemented',
            ),
            participantTargets: participantTargets,
            participantRuntimeProfiles: participantRuntimeProfiles,
            scrollController: scrollController,
            hasEarlier: hasEarlier,
            onLoadEarlier: onLoadEarlier,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

TargetCandidate _flowTarget(String id, String label) => TargetCandidate(
  target: id,
  label: label,
  kind: 'cli',
  status: 'detected',
  configured: true,
  confidence: 1,
  adapterStatus: 'implemented',
);
