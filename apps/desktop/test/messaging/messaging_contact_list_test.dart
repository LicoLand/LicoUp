import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/agent_conversation_tab_activity.dart';
import 'package:licoup/src/contracts/client_conversation_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_contact_list.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_glass_option_card.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shell/layout_palette_projection.dart';
import 'package:licoup/src/frontend/shared/ui/agent_brand_icon.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

void main() {
  testWidgets('search capsule is the first sidebar control', (tester) async {
    var searchCount = 0;
    await _pumpContacts(
      tester,
      sessionsByAgent: const {},
      onSearch: () => searchCount += 1,
    );

    final search = find.byKey(const Key('messaging-sidebar-search'));
    final heading = find.byKey(const Key('messaging-contact-list-heading'));
    expect(search, findsOneWidget);
    expect(
      tester.getTopLeft(search).dy,
      lessThan(tester.getTopLeft(heading).dy),
    );

    final decoration = tester.widget<DecoratedBox>(
      find.descendant(of: search, matching: find.byType(DecoratedBox)),
    );
    expect(
      (decoration.decoration as BoxDecoration).borderRadius,
      BorderRadius.circular(MessagingDesktopMetrics.mainCardCornerRadius),
    );
    final content = tester.widget<Row>(
      find.descendant(of: search, matching: find.byType(Row)),
    );
    expect(content.mainAxisAlignment, MainAxisAlignment.center);

    await tester.tap(search);
    await tester.pump();
    expect(searchCount, 1);
  });

  testWidgets('dark circular identity wells use pure black', (tester) async {
    await _pumpContacts(
      tester,
      sessionsByAgent: const {},
      groupConversations: const [
        ClientConversationSummary(
          id: 'conversation:group',
          title: 'Lico',
          archived: false,
          group: true,
          revision: 1,
          updatedAtUnixMs: 10,
          membershipCount: 2,
          eventCount: 0,
        ),
      ],
      selectedGroupConversationId: 'conversation:group',
    );

    final agentWell = tester.widget<DecoratedBox>(
      find.descendant(
        of: find.byKey(const Key('messaging-contact-codex')),
        matching: find.byKey(const Key('messaging-agent-avatar-well')),
      ),
    );
    expect((agentWell.decoration as BoxDecoration).color, Colors.black);

    final groupWell = tester.widget<Container>(
      find.byKey(const Key('messaging-group-avatar-conversation:group')),
    );
    expect((groupWell.decoration! as BoxDecoration).color, Colors.black);
  });

  testWidgets(
    'target selection shows its reusable conversation list and back row',
    (tester) async {
      final selectedSessions = <String>[];
      var backCount = 0;
      final claude = _target('claude-code', 'Claude Code');
      await _pumpContacts(
        tester,
        targets: [claude],
        sessionsByAgent: {
          claude.id: [
            _session(
              'session-claude',
              claude.target,
              'Refactor list',
              updatedAgo: const Duration(minutes: 5),
              workingDirectory: '/workspace/licoup',
            ),
          ],
        },
        showConversationList: true,
        conversationListTargets: [claude],
        selectedSessionId: 'session-claude',
        onSelectSession: (agentId, sessionId) {
          selectedSessions.add('$agentId/$sessionId');
        },
        onBack: () => backCount += 1,
        onSearch: () {},
        locale: const Locale('zh'),
      );

      expect(
        find.byKey(const Key('messaging-conversation-list')),
        findsOneWidget,
      );
      expect(find.text('返回上一级'), findsOneWidget);
      expect(find.text('Claude'), findsNothing);
      expect(find.text('Refactor list'), findsOneWidget);
      expect(find.byType(AgentBrandIcon), findsNothing);

      final searchRect = tester.getRect(
        find.byKey(const Key('messaging-sidebar-search')),
      );
      final backRect = tester.getRect(
        find.byKey(const Key('messaging-conversation-list-back')),
      );
      final todayRect = tester.getRect(find.text('今天'));
      expect(
        backRect.top - searchRect.bottom,
        MessagingDesktopMetrics.sidebarPrimaryControlGap,
      );
      expect(
        todayRect.top - backRect.bottom,
        MessagingDesktopMetrics.sidebarPrimaryControlGap,
      );
      final backLabel = tester.widget<Text>(
        find.byKey(const Key('messaging-conversation-list-back-label')),
      );
      expect(backLabel.style?.fontSize, 13);
      expect(backLabel.style?.fontWeight, FontWeight.w600);

      await tester.tap(
        find.byKey(const Key('agents-sidebar-conversation-session-claude')),
      );
      await tester.pump();
      expect(selectedSessions, ['claude-code/session-claude']);

      await tester.tap(
        find.byKey(const Key('messaging-conversation-list-back')),
      );
      await tester.pump();
      expect(backCount, 1);
    },
  );

  testWidgets('group conversation list marks every row with its Agent icon', (
    tester,
  ) async {
    final codex = _target('codex', 'Codex');
    final claude = _target('claude-code', 'Claude Code');
    await _pumpContacts(
      tester,
      targets: [codex, claude],
      sessionsByAgent: {
        codex.id: [
          _session(
            'session-codex',
            codex.target,
            'Codex thread',
            updatedAgo: const Duration(minutes: 3),
          ),
        ],
        claude.id: [
          _session(
            'session-claude',
            claude.target,
            'Claude thread',
            updatedAgo: const Duration(minutes: 4),
          ),
        ],
      },
      showConversationList: true,
      conversationListTargets: [codex, claude],
      showConversationAgentIcons: true,
      locale: const Locale('zh'),
    );

    expect(find.text('返回上一级'), findsOneWidget);
    expect(find.text('Local'), findsNothing);
    expect(find.text('Codex thread'), findsOneWidget);
    expect(find.text('Claude thread'), findsOneWidget);
    expect(find.byType(AgentBrandIcon), findsNWidgets(2));
  });

  testWidgets('late Agent scan results prefetch every unloaded history once', (
    tester,
  ) async {
    final prefetched = <String>[];
    final codex = _target('codex', 'Codex');
    final claude = _target('claude-code', 'Claude Code');

    await _pumpContacts(
      tester,
      targets: const [],
      sessionsByAgent: const {},
      onPrefetchSessions: prefetched.add,
    );
    expect(prefetched, isEmpty);

    await _pumpContacts(
      tester,
      targets: [codex, claude],
      sessionsByAgent: {
        codex.id: [
          _session(
            'session-codex',
            codex.target,
            'Already loaded',
            updatedAgo: const Duration(minutes: 2),
          ),
        ],
      },
      onPrefetchSessions: prefetched.add,
    );
    expect(prefetched, [claude.id]);

    await _pumpContacts(
      tester,
      targets: [codex, claude],
      sessionsByAgent: const {},
      onPrefetchSessions: prefetched.add,
    );
    expect(prefetched, [claude.id]);
  });

  testWidgets('canonical multi-Agent group is a fixed pinned first row', (
    tester,
  ) async {
    final selected = <String>[];
    await _pumpContacts(
      tester,
      sessionsByAgent: const {},
      groupConversations: const [
        ClientConversationSummary(
          id: 'conversation:group',
          title: 'Lico',
          archived: false,
          pinned: true,
          group: true,
          revision: 3,
          updatedAtUnixMs: 10,
          membershipCount: 3,
          eventCount: 7,
        ),
      ],
      onSelectGroupConversation: selected.add,
    );

    final group = find.byKey(
      const Key('messaging-group-conversation-conversation:group'),
    );
    final firstAgent = find.byKey(const Key('messaging-contact-codex'));
    expect(group, findsOneWidget);
    expect(
      find.descendant(of: group, matching: find.byIcon(Icons.push_pin_rounded)),
      findsOneWidget,
    );
    expect(
      tester.getTopLeft(group).dy,
      lessThan(tester.getTopLeft(firstAgent).dy),
    );
    expect(find.text('3 members'), findsOneWidget);
    expect(find.textContaining('7 messages'), findsNothing);

    await tester.tap(group);
    await tester.pump();
    expect(selected, ['conversation:group']);
  });

  testWidgets('unpinned groups share recency order with Agent conversations', (
    tester,
  ) async {
    await _pumpContacts(
      tester,
      sessionsByAgent: {
        'codex': [
          _session(
            'session-codex',
            'codex',
            'Recent Codex session',
            updatedAgo: const Duration(minutes: 5),
          ),
        ],
      },
      groupConversations: [
        ClientConversationSummary(
          id: 'conversation:ordinary-group',
          title: 'Older group',
          archived: false,
          group: true,
          revision: 1,
          updatedAtUnixMs: DateTime.now()
              .subtract(const Duration(hours: 2))
              .millisecondsSinceEpoch,
          membershipCount: 2,
          eventCount: 1,
        ),
      ],
    );

    final codex = tester.getTopLeft(
      find.byKey(const Key('messaging-contact-codex')),
    );
    final group = tester.getTopLeft(
      find.byKey(
        const Key('messaging-group-conversation-conversation:ordinary-group'),
      ),
    );
    expect(codex.dy, lessThan(group.dy));
  });

  testWidgets('contacts show brand icon, name, latest preview, and time', (
    tester,
  ) async {
    await _pumpContacts(
      tester,
      sessionsByAgent: {
        'claude-code': [
          _session(
            'session-old',
            'claude-code',
            'Older claude session',
            updatedAgo: const Duration(hours: 3),
            preview: 'older preview',
          ),
          _session(
            'session-new',
            'claude-code',
            'Fresh claude session',
            updatedAgo: const Duration(minutes: 25),
            preview: 'fresh preview',
            workingDirectory: '/work/project-alpha',
          ),
        ],
      },
    );

    final row = find.byKey(const Key('messaging-contact-claude-code'));
    expect(row, findsOneWidget);
    expect(find.text('Conversations'), findsOneWidget);
    expect(
      find.descendant(of: row, matching: find.text('Claude Code')),
      findsOneWidget,
    );
    // The subtitle follows the most recent conversation, not the older one.
    expect(
      find.descendant(
        of: row,
        matching: find.text('fresh preview · project-alpha'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: row, matching: find.text('25m')),
      findsOneWidget,
    );
    final icon = tester.widget<AgentBrandIcon>(
      find.descendant(of: row, matching: find.byType(AgentBrandIcon)),
    );
    expect(icon.target.target, 'claude-code');
    expect(
      find.descendant(of: row, matching: find.byType(SvgPicture)),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('contacts sort by most recent activity across agents', (
    tester,
  ) async {
    await _pumpContacts(
      tester,
      sessionsByAgent: {
        'codex': [
          _session(
            'session-codex',
            'codex',
            'Codex session',
            updatedAgo: const Duration(hours: 2),
          ),
        ],
        'claude-code': [
          _session(
            'session-claude',
            'claude-code',
            'Claude session',
            updatedAgo: const Duration(minutes: 10),
          ),
        ],
      },
    );

    final claude = tester.getTopLeft(
      find.byKey(const Key('messaging-contact-claude-code')),
    );
    final codex = tester.getTopLeft(
      find.byKey(const Key('messaging-contact-codex')),
    );
    final kimi = tester.getTopLeft(
      find.byKey(const Key('messaging-contact-kimi-code')),
    );
    expect(claude.dy, lessThan(codex.dy));
    // Contacts without any conversation sink to the bottom.
    expect(codex.dy, lessThan(kimi.dy));
  });

  testWidgets('tap contact activates the agent for its new-conversation home', (
    tester,
  ) async {
    final activated = <String>[];
    await _pumpContacts(
      tester,
      sessionsByAgent: {
        'claude-code': [
          _session(
            'session-old',
            'claude-code',
            'Older claude session',
            updatedAgo: const Duration(hours: 3),
          ),
          _session(
            'session-new',
            'claude-code',
            'Fresh claude session',
            updatedAgo: const Duration(minutes: 25),
          ),
        ],
      },
      onSelectAgent: activated.add,
    );

    await tester.tap(find.byKey(const Key('messaging-contact-claude-code')));
    await tester.pump();
    expect(activated, ['claude-code']);
  });

  testWidgets('tap contact without conversations activates the agent', (
    tester,
  ) async {
    final activated = <String>[];
    await _pumpContacts(
      tester,
      sessionsByAgent: const {},
      onSelectAgent: activated.add,
    );

    await tester.tap(find.byKey(const Key('messaging-contact-kimi-code')));
    await tester.pump();
    expect(activated, ['kimi-code']);
    expect(find.text('No conversations yet'), findsWidgets);
  });

  testWidgets('merged product stays one contact with the representative icon', (
    tester,
  ) async {
    final activated = <String>[];
    await _pumpContacts(
      tester,
      targets: [
        _target('codex', 'ChatGPT Codex - CLI'),
        _target('codex-desktop', 'Codex - Desktop'),
      ],
      sessionsByAgent: {
        'codex-desktop': [
          _session(
            'session-desktop',
            'codex-desktop',
            'Desktop session',
            updatedAgo: const Duration(minutes: 5),
          ),
        ],
      },
      onSelectAgent: activated.add,
    );

    expect(find.byKey(const Key('messaging-contact-codex')), findsOneWidget);
    expect(
      find.byKey(const Key('messaging-contact-codex-desktop')),
      findsNothing,
    );
    expect(find.text('Codex'), findsOneWidget);
    final row = find.byKey(const Key('messaging-contact-codex'));
    final icon = tester.widget<AgentBrandIcon>(
      find.descendant(of: row, matching: find.byType(AgentBrandIcon)),
    );
    expect(icon.target.target, 'codex');

    await tester.tap(row);
    await tester.pump();
    expect(activated, ['codex']);
  });

  testWidgets('contact activity dot follows the group activity semantics', (
    tester,
  ) async {
    await _pumpContacts(
      tester,
      sessionsByAgent: const {},
      activity: AgentConversationTabActivity.needsApproval,
    );

    expect(
      find.byKey(const Key('messaging-avatar-activity-dot')),
      findsNWidgets(3),
    );
  });

  testWidgets('empty contact list shows the scanning guide', (tester) async {
    await _pumpContacts(tester, targets: const [], sessionsByAgent: const {});

    expect(
      find.byKey(const Key('messaging-contact-list-empty')),
      findsOneWidget,
    );
    expect(find.text('No available agents found'), findsOneWidget);
  });
  testWidgets('unpin toggles the member that owns the pinned state', (
    tester,
  ) async {
    final toggled = <String>[];
    await _pumpContacts(
      tester,
      targets: [
        _target('codex', 'ChatGPT Codex - CLI'),
        _target('codex-desktop', 'Codex - Desktop'),
      ],
      sessionsByAgent: const {},
      // The pinned state lives on the non-first merged member.
      isPinned: (id) => id == 'codex-desktop',
      onTogglePinned: toggled.add,
    );

    final row = find.byKey(const Key('messaging-contact-codex'));
    expect(
      find.descendant(of: row, matching: find.byIcon(Icons.push_pin_rounded)),
      findsOneWidget,
    );

    await tester.tap(row, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('messaging-conversation-item-menu')),
      findsOneWidget,
    );
    expect(find.byType(MessagingGlassOptionCard), findsOneWidget);
    await tester.tap(find.text('Unpin From Top'));
    await tester.pumpAndSettle();

    // The toggle targets the pinned member, not the group representative.
    expect(toggled, ['codex-desktop']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pinned group shares the context menu and can be unpinned', (
    tester,
  ) async {
    final changedIds = <String>[];
    final changedValues = <bool>[];
    await _pumpContacts(
      tester,
      sessionsByAgent: const {},
      groupConversations: const [
        ClientConversationSummary(
          id: 'conversation:group',
          title: 'Lico',
          archived: false,
          pinned: true,
          group: true,
          revision: 3,
          updatedAtUnixMs: 10,
          membershipCount: 3,
          eventCount: 7,
        ),
      ],
      onSetGroupConversationPinned: (conversationId, pinned) {
        changedIds.add(conversationId);
        changedValues.add(pinned);
      },
    );

    final row = find.byKey(
      const Key('messaging-group-conversation-conversation:group'),
    );
    await tester.tap(row, buttons: kSecondaryButton);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('messaging-conversation-item-menu')),
      findsOneWidget,
    );
    expect(find.byType(MessagingGlassOptionCard), findsOneWidget);
    expect(find.text('Unpin From Top'), findsOneWidget);

    await tester.tap(find.text('Unpin From Top'));
    await tester.pumpAndSettle();
    expect(changedIds, ['conversation:group']);
    expect(changedValues, [false]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('selected contact renders solid accent with dark foreground', (
    tester,
  ) async {
    await _pumpContacts(
      tester,
      selectedAgentId: 'codex',
      sessionsByAgent: {
        'codex': [
          _session(
            'session-codex',
            'codex',
            'Codex session',
            updatedAgo: const Duration(minutes: 5),
            preview: 'codex preview',
          ),
        ],
      },
    );

    final colors = tester.element(find.byType(MessagingContactList)).licoColors;
    final row = find.byKey(const Key('messaging-contact-codex'));
    final container = tester.widget<AnimatedContainer>(
      find.descendant(of: row, matching: find.byType(AnimatedContainer)),
    );
    expect((container.decoration! as BoxDecoration).color, colors.primary);
    final title = tester.widget<Text>(
      find.descendant(of: row, matching: find.text('Codex')),
    );
    expect(title.style?.color, colors.textOnPrimary);
    final preview = tester.widget<Text>(
      find.descendant(of: row, matching: find.text('codex preview')),
    );
    expect(preview.style?.color, colors.textOnPrimary.withAlpha(180));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'plus menu opens to the right and dispatches both create actions',
    (tester) async {
      var newConversationCount = 0;
      var newGroupCount = 0;
      await _pumpContacts(
        tester,
        sessionsByAgent: const {},
        locale: const Locale('zh'),
        onNewConversation: () => newConversationCount += 1,
        onNewGroupConversation: () => newGroupCount += 1,
      );

      final plus = find.byTooltip('新建');
      expect(plus, findsOneWidget);
      expect(
        find.descendant(of: plus, matching: find.byIcon(Icons.add_rounded)),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.edit_square), findsNothing);
      expect(find.byIcon(Icons.group_add_outlined), findsNothing);

      await tester.tap(plus);
      await tester.pumpAndSettle();
      final menu = find.byKey(const Key('messaging-create-conversation-menu'));
      expect(menu, findsOneWidget);
      expect(
        tester.getTopLeft(menu).dx,
        greaterThan(tester.getTopRight(plus).dx),
      );
      expect(find.text('新对话'), findsOneWidget);
      expect(find.text('新群组'), findsOneWidget);

      await tester.tap(find.text('新对话'));
      await tester.pumpAndSettle();
      expect(newConversationCount, 1);
      expect(newGroupCount, 0);

      await tester.tap(plus);
      await tester.pumpAndSettle();
      await tester.tap(find.text('新群组'));
      await tester.pumpAndSettle();
      expect(newConversationCount, 1);
      expect(newGroupCount, 1);
      expect(tester.takeException(), isNull);
    },
  );
}

TargetCandidate _target(String target, String label) {
  return TargetCandidate(
    target: target,
    label: label,
    kind: 'cli',
    status: 'detected',
    configured: true,
    confidence: 1,
    adapterStatus: 'implemented',
  );
}

AgentConversationSession _session(
  String id,
  String agentId,
  String title, {
  required Duration updatedAgo,
  String preview = '',
  String workingDirectory = '',
}) {
  final updatedAt = DateTime.now()
      .subtract(updatedAgo)
      .toUtc()
      .toIso8601String();
  return AgentConversationSession(
    id: id,
    agentId: agentId,
    title: title,
    createdAt: updatedAt,
    updatedAt: updatedAt,
    messages: const [],
    workingDirectory: workingDirectory,
    cachedPreview: preview,
  );
}

Future<void> _pumpContacts(
  WidgetTester tester, {
  required Map<String, List<AgentConversationSession>> sessionsByAgent,
  List<TargetCandidate>? targets,
  String selectedAgentId = '',
  ValueChanged<String>? onSelectAgent,
  AgentConversationTabActivity activity = AgentConversationTabActivity.none,
  bool Function(String targetId)? isPinned,
  ValueChanged<String>? onTogglePinned,
  List<ClientConversationSummary> groupConversations = const [],
  String selectedGroupConversationId = '',
  ValueChanged<String>? onSelectGroupConversation,
  void Function(String conversationId, bool pinned)?
  onSetGroupConversationPinned,
  VoidCallback? onNewConversation,
  VoidCallback? onSearch,
  VoidCallback? onNewGroupConversation,
  bool showConversationList = false,
  List<TargetCandidate> conversationListTargets = const [],
  String selectedSessionId = '',
  bool showConversationAgentIcons = false,
  void Function(String agentId, String sessionId)? onSelectSession,
  VoidCallback? onBack,
  ValueChanged<String>? onPrefetchSessions,
  Locale locale = const Locale('en'),
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      supportedLocales: LicoStrings.supportedLocales,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      theme: buildLicoTheme(platformBrightness: Brightness.dark),
      home: Builder(
        builder: (context) => LayoutPaletteScope(
          palette: layoutPaletteFromColors(context.licoColors),
          child: Scaffold(
            body: SizedBox(
              width: 320,
              height: 600,
              child: MessagingContactList(
                targets:
                    targets ??
                    [
                      _target('codex', 'Codex'),
                      _target('claude-code', 'Claude Code'),
                      _target('kimi-code', 'Kimi Code'),
                    ],
                sessionsByAgent: sessionsByAgent,
                selectedAgentId: selectedAgentId,
                activityFor: (_) => activity,
                onSelectAgent: onSelectAgent ?? (_) {},
                onNewConversation: onNewConversation ?? () {},
                onSearch: onSearch,
                onNewGroupConversation: onNewGroupConversation,
                groupConversations: groupConversations,
                selectedGroupConversationId: selectedGroupConversationId,
                onSelectGroupConversation: onSelectGroupConversation,
                onSetGroupConversationPinned: onSetGroupConversationPinned,
                isPinned: isPinned,
                onTogglePinned: onTogglePinned,
                showConversationList: showConversationList,
                conversationListTargets: conversationListTargets,
                selectedSessionId: selectedSessionId,
                showConversationAgentIcons: showConversationAgentIcons,
                onSelectSession: onSelectSession,
                onBack: onBack,
                onPrefetchSessions: onPrefetchSessions,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}
