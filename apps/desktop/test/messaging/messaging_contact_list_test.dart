import 'dart:ui' show SemanticsAction;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_session_presentation.dart';
import 'package:licoup/src/contracts/agent_conversation_tab_activity.dart';
import 'package:licoup/src/contracts/client_conversation_models.dart';
import 'package:licoup/src/contracts/conversation_profile.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_contact_list.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_glass_option_card.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/contracts/presentation/dashboard_feature_order.dart';
import 'package:licoup/src/frontend/shared/dashboard_feature_order_store.dart';
import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/shared/mascot/mascot_catalog.dart';
import 'package:licoup/src/frontend/shared/messaging/conversation_profile_registry.dart';
import 'package:licoup/src/frontend/shared/messaging/messaging_sidebar_navigation.dart';
import 'package:licoup/src/frontend/shared/messaging/messaging_unread_cursor_store.dart';
import 'package:licoup/src/frontend/shared/ui/agent_brand_icon.dart';
import 'package:licoup/src/frontend/shared/ui/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/layout_palette_projection.dart';
import 'package:licoup/src/frontend/shared/ui/lico_selection_highlight.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

import '../layout/fixtures/layout_destination_presentation_fixture.dart';

final class _ContactListOrderStore extends DashboardFeatureOrderStore {
  const _ContactListOrderStore();

  @override
  Future<List<String>> load(Object portableData) async =>
      DashboardFeatureOrder.defaultOrder;

  @override
  Future<void> save(Object portableData, List<String> order) async {}
}

final class _FakeUnreadCursorStore extends MessagingUnreadCursorStore {
  _FakeUnreadCursorStore(this.stored, {this.baselineAtUnixMs = 0});

  Map<String, int>? stored;
  int baselineAtUnixMs;
  final List<Map<String, int>> saves = <Map<String, int>>[];

  @override
  Future<MessagingUnreadCursorSnapshot?> load(Object portableData) async {
    final cursors = stored;
    if (cursors == null) {
      return null;
    }
    return MessagingUnreadCursorSnapshot(
      cursors: cursors,
      baselineAtUnixMs: baselineAtUnixMs,
    );
  }

  @override
  Future<void> save(Object portableData, Map<String, int> cursors) async {
    stored = Map<String, int>.unmodifiable(cursors);
    saves.add(stored!);
  }
}

void main() {
  testWidgets('traffic-light row sits above the search capsule', (
    tester,
  ) async {
    var searchCount = 0;
    await _pumpContacts(
      tester,
      sessionsByAgent: const {},
      onSearch: () => searchCount += 1,
    );

    final search = find.byKey(const Key('messaging-sidebar-search'));
    final lightRow = find.byKey(
      const Key('messaging-sidebar-traffic-light-row'),
    );
    final anchor = find.byKey(const Key('messaging-traffic-light-anchor'));
    expect(search, findsOneWidget);
    expect(lightRow, findsOneWidget);
    expect(anchor, findsOneWidget);
    expect(
      tester.getTopLeft(lightRow).dy,
      lessThan(tester.getTopLeft(search).dy),
    );
    // The heading text above the search capsule is gone.
    expect(
      find.byKey(const Key('messaging-contact-list-heading')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('messaging-conversation-list-back')),
      findsNothing,
    );

    final clip = tester.widget<ClipRRect>(
      find.descendant(of: search, matching: find.byType(ClipRRect)),
    );
    // The search capsule is a stadium: half its token height.
    expect(
      clip.borderRadius,
      BorderRadius.circular(MessagingDesktopMetrics.searchFieldHeight / 2),
    );
    final content = tester.widget<Row>(
      find.descendant(of: search, matching: find.byType(Row)),
    );
    expect(content.mainAxisAlignment, MainAxisAlignment.center);

    await tester.tap(search);
    await tester.pump();
    expect(searchCount, 1);
  });

  testWidgets(
    'in-flight scan occupies space above the first conversation and then disappears',
    (tester) async {
      await _pumpContacts(
        tester,
        sessionsByAgent: const {},
        scanning: true,
        onSearch: () {},
        groupConversations: const [
          ClientConversationSummary(
            id: 'conversation:group',
            title: 'Local room',
            archived: false,
            pinned: true,
            group: true,
            revision: 1,
            updatedAtUnixMs: 20,
            membershipCount: 12,
            eventCount: 0,
          ),
        ],
        selectedGroupConversationId: 'conversation:group',
      );

      final indicator = find.byKey(
        const Key('messaging-list-refresh-indicator'),
      );
      final search = find.byKey(const Key('messaging-sidebar-search'));
      final lightRow = find.byKey(
        const Key('messaging-sidebar-traffic-light-row'),
      );
      final groupRow = find.byKey(
        const ValueKey<String>(
          'messaging-group-conversation-conversation:group',
        ),
      );
      expect(indicator, findsOneWidget);
      expect(find.descendant(of: lightRow, matching: indicator), findsNothing);
      expect(
        tester.getBottomLeft(search).dy,
        lessThanOrEqualTo(tester.getTopLeft(indicator).dy),
      );
      expect(
        tester.getBottomLeft(indicator).dy,
        lessThanOrEqualTo(tester.getTopLeft(groupRow).dy),
      );
      expect(
        tester.getRect(indicator).overlaps(tester.getRect(groupRow)),
        isFalse,
      );

      await _pumpContacts(
        tester,
        sessionsByAgent: const {},
        scanning: false,
        onSearch: () {},
        groupConversations: const [
          ClientConversationSummary(
            id: 'conversation:group',
            title: 'Local room',
            archived: false,
            pinned: true,
            group: true,
            revision: 1,
            updatedAtUnixMs: 20,
            membershipCount: 12,
            eventCount: 0,
          ),
        ],
        selectedGroupConversationId: 'conversation:group',
      );
      expect(indicator, findsNothing);
      expect(groupRow, findsOneWidget);
    },
  );

  testWidgets(
    'a loading agent conversation skeletons its own row, not the list',
    (tester) async {
      await _pumpContacts(
        tester,
        targets: [
          _target('codex', 'Codex'),
          _target('claude-code', 'Claude Code'),
        ],
        sessionsByAgent: {
          'codex': [
            _session(
              's1',
              'codex',
              'Ship it',
              updatedAgo: const Duration(minutes: 5),
              preview: '直接上架',
            ),
          ],
          'claude-code': [
            _session(
              's2',
              'claude-code',
              'Docs',
              updatedAgo: const Duration(hours: 1),
              preview: 'Readme notes',
            ),
          ],
        },
        loading: true,
        loadingAgentIds: const {'codex'},
      );

      final codexRow = find.byKey(const Key('messaging-contact-codex'));
      expect(
        find.descendant(
          of: codexRow,
          matching: find.byKey(const Key('messaging-row-loading-preview')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: codexRow,
          matching: find.byKey(const Key('messaging-row-loading-time')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: codexRow, matching: find.textContaining('直接上架')),
        findsNothing,
      );

      // A settled row keeps its real preview and timestamp.
      final claudeRow = find.byKey(const Key('messaging-contact-claude-code'));
      expect(
        find.descendant(
          of: claudeRow,
          matching: find.byKey(const Key('messaging-row-loading-preview')),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: claudeRow,
          matching: find.textContaining('Readme notes'),
        ),
        findsOneWidget,
      );

      // Per-conversation loading never raises the list-level indicator.
      expect(
        find.byKey(const Key('messaging-list-refresh-indicator')),
        findsNothing,
      );
    },
  );

  testWidgets('a loading group conversation skeletons its row', (tester) async {
    const conversation = ClientConversationSummary(
      id: 'conversation:group',
      title: 'Local room',
      archived: false,
      pinned: false,
      group: true,
      revision: 1,
      updatedAtUnixMs: 20,
      membershipCount: 3,
      eventCount: 0,
    );
    await _pumpContacts(
      tester,
      sessionsByAgent: const {},
      groupConversations: const [conversation],
      loadingGroupConversationId: 'conversation:group',
    );

    final groupRow = find.byKey(
      const ValueKey<String>('messaging-group-conversation-conversation:group'),
    );
    expect(
      find.descendant(
        of: groupRow,
        matching: find.byKey(const Key('messaging-row-loading-preview')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: groupRow,
        matching: find.byKey(const Key('messaging-row-loading-time')),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a profile conversation renders as a mascot contact row', (
    tester,
  ) async {
    resetConversationProfilesForTests();
    addTearDown(resetConversationProfilesForTests);
    addConversationProfile(
      const ConversationProfile(
        id: 'nova',
        name: 'Nova',
        mascotAvatarId: 'luna',
        agentId: 'codex',
        createdAtUnixMs: 1,
        conversationId: 'conversation:profile-nova',
      ),
    );
    const conversation = ClientConversationSummary(
      id: 'conversation:profile-nova',
      title: 'Nova',
      archived: false,
      pinned: false,
      group: false,
      revision: 1,
      updatedAtUnixMs: 20,
      membershipCount: 2,
      eventCount: 1,
    );
    await _pumpContacts(
      tester,
      sessionsByAgent: const {},
      directConversations: const [conversation],
    );

    final row = find.byKey(
      const ValueKey<String>(
        'messaging-profile-conversation-conversation:profile-nova',
      ),
    );
    expect(row, findsOneWidget);
    expect(
      find.descendant(
        of: row,
        matching: find.byKey(
          const ValueKey<String>(
            'messaging-profile-avatar-conversation:profile-nova',
          ),
        ),
      ),
      findsOneWidget,
    );
    expect(find.text('Nova'), findsOneWidget);
    // The backing agent's product name is the row subtitle.
    expect(
      find.descendant(of: row, matching: find.text('Codex')),
      findsOneWidget,
    );
  });

  testWidgets(
    'a direct conversation with no registered profile renders no row',
    (tester) async {
      resetConversationProfilesForTests();
      addTearDown(resetConversationProfilesForTests);
      const conversation = ClientConversationSummary(
        id: 'conversation:legacy-1to1',
        title: 'codex',
        archived: false,
        pinned: false,
        group: false,
        revision: 1,
        updatedAtUnixMs: 20,
        membershipCount: 2,
        eventCount: 1,
      );
      await _pumpContacts(
        tester,
        sessionsByAgent: const {},
        directConversations: const [conversation],
      );

      expect(
        find.byKey(
          const ValueKey<String>(
            'messaging-profile-conversation-conversation:legacy-1to1',
          ),
        ),
        findsNothing,
      );
      expect(find.text('codex'), findsNothing);
    },
  );

  testWidgets(
    'profile conversations list under Agents and never under Groups',
    (tester) async {
      resetConversationProfilesForTests();
      addTearDown(resetConversationProfilesForTests);
      addConversationProfile(
        const ConversationProfile(
          id: 'nova',
          name: 'Nova',
          mascotAvatarId: 'luna',
          agentId: 'codex',
          createdAtUnixMs: 1,
          conversationId: 'conversation:profile-nova',
        ),
      );
      const direct = ClientConversationSummary(
        id: 'conversation:profile-nova',
        title: 'Nova',
        archived: false,
        pinned: false,
        group: false,
        revision: 1,
        updatedAtUnixMs: 20,
        membershipCount: 2,
        eventCount: 1,
      );
      const group = ClientConversationSummary(
        id: 'conversation:group',
        title: 'Local room',
        archived: false,
        pinned: false,
        group: true,
        revision: 1,
        updatedAtUnixMs: 19,
        membershipCount: 3,
        eventCount: 0,
      );
      await _pumpContacts(
        tester,
        sessionsByAgent: const {},
        groupConversations: const [group],
        directConversations: const [direct],
        presentation: const FixtureLayoutAgentsPresentation(
          showConversationFilters: true,
        ),
      );

      final profileRow = find.byKey(
        const ValueKey<String>(
          'messaging-profile-conversation-conversation:profile-nova',
        ),
      );
      final groupRow = find.byKey(
        const ValueKey<String>(
          'messaging-group-conversation-conversation:group',
        ),
      );
      expect(profileRow, findsOneWidget);
      expect(groupRow, findsOneWidget);

      await tester.tap(
        find.byKey(const Key('messaging-conversation-filter-agents')),
      );
      await tester.pumpAndSettle();
      expect(profileRow, findsOneWidget);
      expect(groupRow, findsNothing);

      await tester.tap(
        find.byKey(const Key('messaging-conversation-filter-groups')),
      );
      await tester.pumpAndSettle();
      expect(profileRow, findsNothing);
      expect(groupRow, findsOneWidget);
    },
  );

  testWidgets(
    'contact list shows host-local agents and hides Hub-absent installs',
    (tester) async {
      final workingDirectory = ['', 'srv', 'project'].join('/');
      await _pumpContacts(
        tester,
        targets: [
          _target('codex', 'Codex'),
          TargetCandidate(
            target: 'hermes',
            label: 'Hermes Agent',
            kind: 'cli',
            status: 'detected',
            configured: true,
            confidence: 1,
            binaryPath: 'hermes',
            adapterStatus: 'implemented',
            location: 'virtual-machine',
            scanSource: 'virtual-machine-orbstack',
            runtimeConnection: {
              'kind': 'ssh',
              'host': 'orb',
              'remoteExecutable': 'hermes',
              'workingDirectory': workingDirectory,
              'runtimeProtocol': 'hermes-tui-gateway',
            },
          ),
          TargetCandidate(
            target: 'openclaw',
            label: 'OpenClaw',
            kind: 'cli',
            status: 'not-detected',
            configured: false,
            confidence: 0.15,
            adapterStatus: 'implemented',
          ),
        ],
        sessionsByAgent: const {},
      );

      expect(find.byKey(const Key('messaging-contact-codex')), findsOneWidget);
      expect(find.byKey(const Key('messaging-contact-hermes')), findsNothing);
      expect(find.byKey(const Key('messaging-contact-openclaw')), findsNothing);
    },
  );

  testWidgets(
    'agent rows use bare marks and the empty mosaic well stays black',
    (tester) async {
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

      // Agent rows render the bare brand mark — the identity well is gone.
      expect(
        find.descendant(
          of: find.byKey(const Key('messaging-contact-codex')),
          matching: find.byType(AgentBrandIcon),
        ),
        findsOneWidget,
      );

      // No member data in the summary falls back to the generic circular well
      // inside the mosaic avatar.
      final groupWell = tester.widget<Container>(
        find.descendant(
          of: find.byKey(
            const Key('messaging-group-avatar-conversation:group'),
          ),
          matching: find.byType(Container),
        ),
      );
      expect((groupWell.decoration! as BoxDecoration).color, Colors.black);
    },
  );

  testWidgets('group row mosaic paints member cells from the summary', (
    tester,
  ) async {
    final claude = _target('claude-code', 'Claude Code');
    await _pumpContacts(
      tester,
      targets: [claude],
      sessionsByAgent: const {},
      groupConversations: const [
        ClientConversationSummary(
          id: 'conversation:group',
          title: 'Lico',
          archived: false,
          group: true,
          revision: 1,
          updatedAtUnixMs: 10,
          membershipCount: 3,
          eventCount: 0,
          memberAgentIds: ['claude-code'],
          hasLocalOwner: true,
        ),
      ],
    );

    final avatar = find.byKey(
      const Key('messaging-group-avatar-conversation:group'),
    );
    // The local owner's cell paints the session mascot tile and the resolved
    // agent cell its brand mark; the generic circular mark stays only for
    // empty rosters.
    expect(
      find.descendant(of: avatar, matching: find.byType(AgentBrandIcon)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: avatar, matching: find.byType(MascotImage)),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: avatar,
        matching: find.byIcon(Icons.groups_2_rounded),
      ),
      findsNothing,
    );
  });

  testWidgets(
    'contact row previews the latest parent session and a tap opens it',
    (tester) async {
      final selectedAgents = <String>[];
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
              preview: 'Reworked the row',
              workingDirectory: '/workspace/licoup',
            ),
            // A newer sub-agent thread never becomes the contact preview.
            _session(
              'session-child',
              claude.target,
              'Sub-agent thread',
              updatedAgo: Duration.zero,
              preview: 'Should never surface',
              parentSessionId: 'session-claude',
            ),
          ],
        },
        onSelectAgent: selectedAgents.add,
        onSearch: () {},
      );

      final row = find.byKey(const Key('messaging-contact-claude-code'));
      expect(row, findsOneWidget);
      expect(find.text('Reworked the row · licoup'), findsOneWidget);
      expect(find.text('Should never surface'), findsNothing);
      // The removed drill-down level leaves no back control anywhere.
      expect(
        find.byKey(const Key('messaging-conversation-list')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('messaging-conversation-list-back')),
        findsNothing,
      );
      expect(find.text('返回上一级'), findsNothing);

      await tester.tap(row);
      await tester.pump();
      expect(selectedAgents, [claude.id]);
    },
  );

  testWidgets(
    'traffic-light row and search stay pinned while contacts scroll',
    (tester) async {
      final claude = _target('claude-code', 'Claude Code');
      await _pumpContacts(
        tester,
        targets: [
          claude,
          for (var index = 0; index < 16; index++)
            _target('agent-$index', 'Agent $index'),
        ],
        sessionsByAgent: {
          claude.id: [
            _session(
              'session-0',
              claude.target,
              'Thread 0',
              updatedAgo: const Duration(minutes: 1),
            ),
          ],
        },
        onSearch: () {},
      );

      final lightRow = find.byKey(
        const Key('messaging-sidebar-traffic-light-row'),
      );
      final search = find.byKey(const Key('messaging-sidebar-search'));
      expect(lightRow, findsOneWidget);
      expect(search, findsOneWidget);
      expect(
        tester.getTopLeft(lightRow).dy,
        lessThan(tester.getTopLeft(search).dy),
      );

      final lightRowY = tester.getTopLeft(lightRow).dy;
      final searchY = tester.getTopLeft(search).dy;
      final visibleRow = find.byKey(const Key('messaging-contact-agent-3'));
      expect(visibleRow, findsOneWidget);
      final visibleRowY = tester.getTopLeft(visibleRow).dy;
      await tester.drag(
        find.byKey(const Key('messaging-contact-scroll')),
        const Offset(0, -80),
      );
      await tester.pump();

      expect(tester.getTopLeft(lightRow).dy, lightRowY);
      expect(tester.getTopLeft(search).dy, searchY);
      expect(tester.getTopLeft(visibleRow).dy, lessThan(visibleRowY));
    },
  );

  testWidgets('each contact keeps one row with its brand icon', (tester) async {
    final fixtureNow = DateTime(2026, 10, 12, 12);
    conversationNow = () => fixtureNow;
    addTearDown(() => conversationNow = DateTime.now);
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
            preview: 'Codex is working',
          ),
        ],
        claude.id: [
          _session(
            'session-claude',
            claude.target,
            'Claude thread',
            updatedAgo: const Duration(minutes: 4),
            preview: 'Claude replied',
          ),
        ],
      },
    );

    expect(find.byKey(const Key('messaging-contact-codex')), findsOneWidget);
    expect(
      find.byKey(const Key('messaging-contact-claude-code')),
      findsOneWidget,
    );
    expect(find.text('Codex is working'), findsOneWidget);
    expect(find.text('Claude replied'), findsOneWidget);
    // Same-day sessions show the demo's HH:mm clock.
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            RegExp(r'^\d{2}:\d{2}$').hasMatch(widget.data ?? ''),
      ),
      findsNWidgets(2),
    );
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
      sessionsByAgent: {
        codex.id: [
          _session(
            'session-codex',
            codex.target,
            'Already loaded',
            updatedAgo: const Duration(minutes: 2),
          ),
        ],
        claude.id: const [],
      },
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
    expect(
      find.descendant(of: group, matching: find.text('3')),
      findsOneWidget,
    );
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
    final fixtureNow = DateTime(2026, 10, 12, 12);
    conversationNow = () => fixtureNow;
    addTearDown(() => conversationNow = DateTime.now);
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
      find.descendant(
        of: row,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Text &&
              RegExp(r'^\d{2}:\d{2}$').hasMatch(widget.data ?? ''),
        ),
      ),
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

  testWidgets('group menu places archive below pin and dispatches both', (
    tester,
  ) async {
    final changedIds = <String>[];
    final changedValues = <bool>[];
    final archivedIds = <String>[];
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
      onArchiveGroupConversation: archivedIds.add,
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
    expect(find.text('Archive'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Unpin From Top')).dy,
      lessThan(tester.getTopLeft(find.text('Archive')).dy),
    );

    await tester.tap(find.text('Unpin From Top'));
    await tester.pumpAndSettle();
    expect(changedIds, ['conversation:group']);
    expect(changedValues, [false]);

    await tester.tap(row, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archive'));
    await tester.pumpAndSettle();
    expect(archivedIds, ['conversation:group']);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'selected contact renders the violet surface with normal foreground',
    (tester) async {
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

      final colors = tester
          .element(find.byType(MessagingContactList))
          .licoColors;
      final row = find.byKey(const Key('messaging-contact-codex'));
      final container = tester.widget<AnimatedContainer>(
        find.descendant(of: row, matching: find.byType(AnimatedContainer)),
      );
      // Fluorescent highlight, not a solid fill: the decoration stays
      // transparent and the accent pill + wash ride on the CustomPaint.
      expect(
        (container.decoration! as BoxDecoration).color,
        Colors.transparent,
      );
      final paint = tester.widget<CustomPaint>(
        find.descendant(of: row, matching: find.byType(CustomPaint)),
      );
      expect(paint.painter, isA<LicoSelectionHighlightPainter>());
      final title = tester.widget<Text>(
        find.descendant(of: row, matching: find.text('Codex')),
      );
      expect(title.style?.color, colors.selectionInk);
      final preview = tester.widget<Text>(
        find.descendant(of: row, matching: find.text('codex preview')),
      );
      expect(preview.style?.color, colors.textMuted);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('starlight keeps the selected title in the plain text tone', (
    tester,
  ) async {
    await _pumpContacts(
      tester,
      selectedAgentId: 'codex',
      treatment: LicoSelectionTreatment.starlight,
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
    expect(
      find.descendant(
        of: row,
        matching: find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is LicoStarlightHighlightPainter,
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: row,
        matching: find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is LicoSelectionHighlightPainter,
        ),
      ),
      findsNothing,
    );
    final title = tester.widget<Text>(
      find.descendant(of: row, matching: find.text('Codex')),
    );
    expect(title.style?.color, colors.text);
    expect(tester.takeException(), isNull);
  });

  testWidgets('group row shows the unread delta over the stored cursor', (
    tester,
  ) async {
    final store = _FakeUnreadCursorStore(const {'conversation:group': 3});
    await _pumpContacts(
      tester,
      sessionsByAgent: const {},
      unreadCursorStore: store,
      groupConversations: const [
        ClientConversationSummary(
          id: 'conversation:group',
          title: 'Local',
          archived: false,
          group: true,
          revision: 1,
          updatedAtUnixMs: 10,
          membershipCount: 4,
          eventCount: 5,
        ),
      ],
    );
    await tester.pump();

    final badge = find.byKey(
      const Key('messaging-unread-badge-conversation:group'),
    );
    expect(badge, findsOneWidget);
    expect(
      find.descendant(of: badge, matching: find.text('2')),
      findsOneWidget,
    );
  });

  testWidgets('tapping an unread row marks it seen', (tester) async {
    var selected = '';
    final store = _FakeUnreadCursorStore(const {'conversation:group': 3});
    await _pumpContacts(
      tester,
      sessionsByAgent: const {},
      unreadCursorStore: store,
      onSelectGroupConversation: (id) => selected = id,
      groupConversations: const [
        ClientConversationSummary(
          id: 'conversation:group',
          title: 'Local',
          archived: false,
          group: true,
          revision: 1,
          updatedAtUnixMs: 10,
          membershipCount: 4,
          eventCount: 5,
        ),
      ],
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const Key('messaging-group-conversation-conversation:group')),
    );
    await tester.pump();

    expect(selected, 'conversation:group');
    expect(store.stored?['conversation:group'], 5);
    expect(
      find.byKey(const Key('messaging-unread-badge-conversation:group')),
      findsNothing,
    );
  });

  testWidgets('the open conversation can never show unread', (tester) async {
    final store = _FakeUnreadCursorStore(const {'conversation:group': 3});
    await _pumpContacts(
      tester,
      sessionsByAgent: const {},
      unreadCursorStore: store,
      selectedGroupConversationId: 'conversation:group',
      groupConversations: const [
        ClientConversationSummary(
          id: 'conversation:group',
          title: 'Local',
          archived: false,
          group: true,
          revision: 1,
          updatedAtUnixMs: 10,
          membershipCount: 4,
          eventCount: 7,
        ),
      ],
    );
    await tester.pump();

    expect(
      find.byKey(const Key('messaging-unread-badge-conversation:group')),
      findsNothing,
    );
    expect(store.stored?['conversation:group'], 7);
  });

  testWidgets('first run seeds known conversations without badging', (
    tester,
  ) async {
    final store = _FakeUnreadCursorStore(null);
    await _pumpContacts(
      tester,
      sessionsByAgent: const {},
      unreadCursorStore: store,
      groupConversations: const [
        ClientConversationSummary(
          id: 'conversation:group',
          title: 'Local',
          archived: false,
          group: true,
          revision: 1,
          updatedAtUnixMs: 10,
          membershipCount: 4,
          eventCount: 9,
        ),
      ],
    );
    await tester.pump();

    expect(
      find.byKey(const Key('messaging-unread-badge-conversation:group')),
      findsNothing,
    );
    expect(store.stored?['conversation:group'], 9);
  });

  testWidgets('an agent row badges its latest session delta', (tester) async {
    final store = _FakeUnreadCursorStore(const {'session-codex': 1});
    await _pumpContacts(
      tester,
      unreadCursorStore: store,
      sessionsByAgent: {
        'codex': [
          _session(
            'session-codex',
            'codex',
            'Codex session',
            updatedAgo: const Duration(minutes: 5),
            preview: 'codex preview',
            messageCount: 4,
          ),
        ],
      },
    );
    await tester.pump();

    final badge = find.byKey(const Key('messaging-unread-badge-session-codex'));
    expect(badge, findsOneWidget);
    expect(
      find.descendant(of: badge, matching: find.text('3')),
      findsOneWidget,
    );
  });

  testWidgets('agent row badge sums unread across all sessions', (
    tester,
  ) async {
    final store = _FakeUnreadCursorStore(const {
      'session-new': 2,
      'session-old': 1,
    });
    await _pumpContacts(
      tester,
      unreadCursorStore: store,
      sessionsByAgent: {
        'codex': [
          _session(
            'session-new',
            'codex',
            'New',
            updatedAgo: const Duration(minutes: 1),
            messageCount: 4,
          ),
          _session(
            'session-old',
            'codex',
            'Old',
            updatedAgo: const Duration(minutes: 30),
            messageCount: 3,
          ),
        ],
      },
    );
    await tester.pump();

    // (4-2) + (3-1) = 4 unread across both sessions.
    final badge = find.byKey(const Key('messaging-unread-badge-session-new'));
    expect(badge, findsOneWidget);
    expect(
      find.descendant(of: badge, matching: find.text('4')),
      findsOneWidget,
    );
  });

  testWidgets('agent row shows a status pill instead of the unread badge', (
    tester,
  ) async {
    Future<void> pump({
      bool Function(AgentConversationSession session)? runningFor,
      AgentConversationTabActivity activity = AgentConversationTabActivity.none,
    }) => _pumpContacts(
      tester,
      unreadCursorStore: _FakeUnreadCursorStore(const {'session-codex': 1}),
      targets: [_target('codex', 'Codex')],
      runningFor: runningFor,
      activity: activity,
      sessionsByAgent: {
        'codex': [
          _session(
            'session-codex',
            'codex',
            'Codex session',
            updatedAgo: const Duration(minutes: 5),
            messageCount: 4,
          ),
        ],
      },
    );

    await pump(runningFor: (_) => true);
    await tester.pump();
    expect(
      find.byKey(const Key('messaging-row-status-working')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('messaging-unread-badge-session-codex')),
      findsNothing,
    );

    await pump(activity: AgentConversationTabActivity.needsApproval);
    await tester.pump();
    expect(
      find.byKey(const Key('messaging-row-status-approval')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('messaging-unread-badge-session-codex')),
      findsNothing,
    );

    await pump(activity: AgentConversationTabActivity.workFinished);
    await tester.pump();
    expect(
      find.byKey(const Key('messaging-row-status-finished')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('messaging-unread-badge-session-codex')),
      findsNothing,
    );

    await pump();
    await tester.pump();
    for (final key in const [
      'messaging-row-status-working',
      'messaging-row-status-approval',
      'messaging-row-status-finished',
    ]) {
      expect(find.byKey(Key(key)), findsNothing);
    }
    expect(
      find.byKey(const Key('messaging-unread-badge-session-codex')),
      findsOneWidget,
    );
  });

  testWidgets('contact taps open the newest unread session, then the next, '
      'then fall back once all are read', (tester) async {
    final opened = <(String, String)>[];
    final fallback = <String>[];
    final store = _FakeUnreadCursorStore(const {
      'session-new': 2,
      'session-old': 1,
    });
    await _pumpContacts(
      tester,
      unreadCursorStore: store,
      onSelectAgent: fallback.add,
      onSelectAgentSession: (agentId, sessionId) =>
          opened.add((agentId, sessionId)),
      sessionsByAgent: {
        'codex': [
          _session(
            'session-new',
            'codex',
            'New',
            updatedAgo: const Duration(minutes: 1),
            messageCount: 4,
          ),
          _session(
            'session-old',
            'codex',
            'Old',
            updatedAgo: const Duration(minutes: 30),
            messageCount: 3,
          ),
        ],
      },
    );
    await tester.pump();

    final row = find.byKey(const Key('messaging-contact-codex'));
    await tester.tap(row);
    await tester.pump();
    // First tap opens the newest session that still has unread and marks
    // it read.
    expect(opened, [('codex', 'session-new')]);
    expect(store.stored?['session-new'], 4);

    await tester.tap(row);
    await tester.pump();
    // The next tap finds the next-most-recent unread session.
    expect(opened.last, ('codex', 'session-old'));
    expect(store.stored?['session-old'], 3);

    await tester.tap(row);
    await tester.pump();
    // All sessions read: the tap falls back to the default open action.
    expect(opened, hasLength(2));
    expect(fallback, ['codex']);
    expect(
      find.byKey(const Key('messaging-unread-badge-session-new')),
      findsNothing,
    );
  });

  testWidgets('sessions idle since before the coverage baseline are adopted '
      'read on first sight and persisted', (tester) async {
    final store = _FakeUnreadCursorStore(
      const {},
      baselineAtUnixMs: DateTime.now()
          .subtract(const Duration(hours: 1))
          .millisecondsSinceEpoch,
    );
    await _pumpContacts(
      tester,
      unreadCursorStore: store,
      sessionsByAgent: {
        'codex': [
          _session(
            'session-recent',
            'codex',
            'Recent',
            updatedAgo: const Duration(hours: 2),
            messageCount: 4,
          ),
          _session(
            'session-old',
            'codex',
            'Old',
            updatedAgo: const Duration(hours: 3),
            messageCount: 3,
          ),
        ],
      },
    );
    await tester.pump();
    await tester.pump();

    expect(
      find.byKey(const Key('messaging-unread-badge-session-recent')),
      findsNothing,
    );
    expect(store.stored?['session-recent'], 4);
    expect(store.stored?['session-old'], 3);
  });

  testWidgets('sessions active after the coverage baseline badge in full '
      'and drive the unread tap', (tester) async {
    final opened = <(String, String)>[];
    final store = _FakeUnreadCursorStore(
      const {},
      baselineAtUnixMs: DateTime.now()
          .subtract(const Duration(hours: 1))
          .millisecondsSinceEpoch,
    );
    await _pumpContacts(
      tester,
      unreadCursorStore: store,
      onSelectAgentSession: (agentId, sessionId) =>
          opened.add((agentId, sessionId)),
      sessionsByAgent: {
        'codex': [
          _session(
            'session-new',
            'codex',
            'New',
            updatedAgo: const Duration(minutes: 30),
            messageCount: 4,
          ),
          _session(
            'session-old',
            'codex',
            'Old',
            updatedAgo: const Duration(hours: 3),
            messageCount: 3,
          ),
        ],
      },
    );
    await tester.pump();

    final badge = find.byKey(const Key('messaging-unread-badge-session-new'));
    expect(badge, findsOneWidget);
    expect(
      find.descendant(of: badge, matching: find.text('4')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('messaging-contact-codex')));
    await tester.pump();
    expect(opened, [('codex', 'session-new')]);
    expect(store.stored?['session-new'], 4);
  });

  testWidgets(
    'plus menu opens to the right and dispatches all create actions',
    (tester) async {
      var newConversationCount = 0;
      var newGroupCount = 0;
      var newProfileCount = 0;
      await _pumpContacts(
        tester,
        sessionsByAgent: const {},
        locale: const Locale('zh'),
        onNewConversation: () => newConversationCount += 1,
        onNewGroupConversation: () => newGroupCount += 1,
        onNewAgentProfile: () => newProfileCount += 1,
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
      expect(
        find.byKey(const Key('messaging-create-conversation')),
        findsOneWidget,
      );
      final menu = find.byKey(const Key('messaging-create-conversation-menu'));
      expect(menu, findsOneWidget);
      expect(
        tester.getTopLeft(menu).dx,
        greaterThan(tester.getTopRight(plus).dx),
      );
      expect(find.text('新对话'), findsOneWidget);
      expect(find.text('新群组'), findsOneWidget);
      expect(find.text('创建智能体'), findsOneWidget);

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
      expect(newProfileCount, 0);

      await tester.tap(plus);
      await tester.pumpAndSettle();
      await tester.tap(find.text('创建智能体'));
      await tester.pumpAndSettle();
      expect(newProfileCount, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('bottom nav lists features, chats, and settings', (tester) async {
    await _pumpContacts(
      tester,
      sessionsByAgent: const {},
      locale: const Locale('zh'),
    );

    expect(
      find.byKey(const Key('messaging-sidebar-foundation')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('messaging-sidebar-bottom-nav')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('messaging-sidebar-nav-features')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('messaging-sidebar-nav-conversations')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('messaging-sidebar-nav-settings')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('messaging-sidebar-nav-communication')),
      findsNothing,
    );
    expect(find.byKey(const Key('messaging-sidebar-nav-skills')), findsNothing);
    final bottomNav = find.byKey(const Key('messaging-sidebar-bottom-nav'));
    expect(
      find.descendant(of: bottomNav, matching: find.text('功能')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: bottomNav, matching: find.text('对话')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: bottomNav, matching: find.text('设置')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: bottomNav, matching: find.text('通信')),
      findsNothing,
    );
    expect(
      tester
          .getTopLeft(find.byKey(const Key('messaging-sidebar-nav-features')))
          .dx,
      lessThan(
        tester
            .getTopLeft(
              find.byKey(const Key('messaging-sidebar-nav-conversations')),
            )
            .dx,
      ),
    );
    expect(
      tester
          .getTopLeft(
            find.byKey(const Key('messaging-sidebar-nav-conversations')),
          )
          .dx,
      lessThan(
        tester
            .getTopLeft(find.byKey(const Key('messaging-sidebar-nav-settings')))
            .dx,
      ),
    );
    expect(
      tester
          .widget<Icon>(
            find.descendant(
              of: find.byKey(const Key('messaging-sidebar-nav-features')),
              matching: find.byType(Icon),
            ),
          )
          .icon,
      Icons.functions,
    );
    expect(
      find.byKey(const Key('messaging-sidebar-nav-plugins')),
      findsNothing,
    );
    expect(find.byKey(const Key('messaging-contact-codex')), findsOneWidget);
    expect(
      find.byKey(const Key('messaging-sidebar-settings-list')),
      findsNothing,
    );
  });

  testWidgets('settings tab shows the settings section list in the sidebar', (
    tester,
  ) async {
    await _pumpContacts(
      tester,
      sessionsByAgent: const {},
      activeDestination: ClientSection.settings,
      locale: const Locale('zh'),
    );

    expect(
      find.byKey(const Key('messaging-sidebar-settings-list')),
      findsOneWidget,
    );
    expect(find.text('外观'), findsOneWidget);
    expect(find.text('更新'), findsOneWidget);
    expect(find.text('通用'), findsOneWidget);
    expect(find.text('工具'), findsNothing);
    expect(find.text('存储'), findsOneWidget);
    expect(find.text('诊断'), findsOneWidget);
    expect(find.text('启动'), findsOneWidget);
    expect(find.text('归档'), findsOneWidget);
    expect(find.byKey(const Key('messaging-contact-codex')), findsNothing);
    expect(
      find.byKey(const Key('messaging-sidebar-bottom-nav')),
      findsOneWidget,
    );
  });

  testWidgets('conversation tab keeps the conversation list above the nav', (
    tester,
  ) async {
    await _pumpContacts(tester, sessionsByAgent: const {});

    expect(find.byKey(const Key('messaging-contact-list')), findsOneWidget);
    expect(find.byKey(const Key('messaging-contact-codex')), findsOneWidget);
    expect(
      find.byKey(const Key('messaging-sidebar-settings-list')),
      findsNothing,
    );
    expect(
      tester.getTopLeft(find.byKey(const Key('messaging-contact-codex'))).dy,
      lessThan(
        tester
            .getTopLeft(find.byKey(const Key('messaging-sidebar-bottom-nav')))
            .dy,
      ),
    );
  });

  testWidgets(
    'active bottom-nav item uses the shared selection surface and ink',
    (tester) async {
      await _pumpContacts(tester, sessionsByAgent: const {});

      final colors = tester
          .element(find.byType(MessagingContactList))
          .licoColors;
      final selected = find.byKey(
        const Key('messaging-sidebar-nav-conversations'),
      );
      // The nav row stays fill-free; selection is the shared fluorescent
      // highlight painter, with selectionInk icon and text.
      final container = tester.widget<AnimatedContainer>(
        find.descendant(of: selected, matching: find.byType(AnimatedContainer)),
      );
      expect(
        (container.decoration! as BoxDecoration).color,
        Colors.transparent,
      );
      final paint = tester.widget<CustomPaint>(
        find.descendant(of: selected, matching: find.byType(CustomPaint)),
      );
      expect(paint.painter, isA<LicoSelectionHighlightPainter>());
      final icon = tester.widget<Icon>(
        find.descendant(of: selected, matching: find.byType(Icon)),
      );
      expect(icon.color, colors.selectionInk);
      final label = tester.widget<Text>(
        find.descendant(of: selected, matching: find.text('Chats')),
      );
      expect(label.style?.color, colors.selectionInk);

      final skills = find.byKey(const Key('messaging-sidebar-nav-features'));
      final skillsContainer = tester.widget<AnimatedContainer>(
        find.descendant(of: skills, matching: find.byType(AnimatedContainer)),
      );
      expect(
        (skillsContainer.decoration! as BoxDecoration).color,
        isNot(colors.primary),
      );
    },
  );

  testWidgets('contact list forwards pull refresh', (tester) async {
    var refreshes = 0;
    await _pumpContacts(
      tester,
      sessionsByAgent: const {},
      onRefresh: () => refreshes += 1,
    );
    final list = find.byType(ListView);
    await tester.drag(list, const Offset(0, 220));
    await tester.pumpAndSettle();
    expect(refreshes, 1);
    expect(
      tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels,
      0,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('labeled bottom tabs have no hover bubbles and keep semantics', (
    tester,
  ) async {
    await _pumpContacts(tester, sessionsByAgent: const {});
    final semantics = tester.ensureSemantics();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: const Offset(700, 500));
    for (final item in MessagingSidebarNavItem.values) {
      final button = find.byKey(Key(messagingSidebarNavKey(item)));
      expect(
        find.descendant(of: button, matching: find.byType(Tooltip)),
        findsNothing,
      );
      final node = tester.getSemantics(button);
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      expect(node.label, isNotEmpty);
      await mouse.moveTo(tester.getCenter(button));
      await tester.pump(const Duration(seconds: 1));
      await mouse.moveTo(const Offset(700, 500));
      await tester.pump(const Duration(seconds: 1));
      expect(
        find.descendant(
          of: find.byKey(const Key('messaging-sidebar-bottom-nav')),
          matching: find.byType(Tooltip),
        ),
        findsNothing,
      );
    }
    semantics.dispose();
  });

  testWidgets('bottom nav maps the three tabs onto existing destinations', (
    tester,
  ) async {
    final selected = <ClientSection>[];
    await _pumpContacts(
      tester,
      sessionsByAgent: const {},
      onSelectDestination: selected.add,
      activeDestination: ClientSection.pluginManagement,
    );

    await tester.tap(
      find.byKey(const Key('messaging-sidebar-nav-conversations')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('messaging-sidebar-nav-features')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('messaging-sidebar-nav-settings')));
    await tester.pump();

    expect(selected, [
      ClientSection.agents,
      ClientSection.pluginManagement,
      ClientSection.settings,
    ]);
  });

  testWidgets('features tab from chats opens agent hub', (tester) async {
    final selected = <ClientSection>[];
    await _pumpContacts(
      tester,
      sessionsByAgent: const {},
      onSelectDestination: selected.add,
    );

    await tester.tap(find.byKey(const Key('messaging-sidebar-nav-features')));
    await tester.pump();

    expect(selected, [ClientSection.agentHub]);
  });

  testWidgets('plain presentation shows the title, compose and filter chips '
      'without the bottom nav', (tester) async {
    await _pumpContacts(
      tester,
      sessionsByAgent: const {},
      onSearch: () {},
      presentation: const FixtureLayoutAgentsPresentation.docked(),
    );

    expect(find.byKey(const Key('messaging-sidebar-title')), findsOneWidget);
    expect(find.text('Messages'), findsWidgets);
    expect(
      find.byKey(const Key('messaging-create-conversation')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('messaging-conversation-filters')),
      findsOneWidget,
    );
    for (final chip in <String>['all', 'agents', 'groups']) {
      expect(
        find.byKey(Key('messaging-conversation-filter-$chip')),
        findsOneWidget,
      );
    }
    // The rail owns navigation: no bottom tabs and no traffic-light row.
    expect(find.byKey(const Key('messaging-sidebar-bottom-nav')), findsNothing);
    expect(
      find.byKey(const Key('messaging-sidebar-traffic-light-row')),
      findsNothing,
    );
  });

  testWidgets('plain filter chips narrow the conversation rows', (
    tester,
  ) async {
    await _pumpContacts(
      tester,
      sessionsByAgent: {
        'codex': [
          _session('s1', 'codex', 'Fix bug', updatedAgo: Duration.zero),
        ],
      },
      groupConversations: const [
        ClientConversationSummary(
          id: 'conversation:group',
          title: 'Local room',
          archived: false,
          pinned: false,
          group: true,
          revision: 1,
          updatedAtUnixMs: 20,
          membershipCount: 3,
          eventCount: 0,
        ),
      ],
      presentation: const FixtureLayoutAgentsPresentation.docked(),
    );

    final agentRow = find.byKey(const Key('messaging-contact-codex'));
    final groupRow = find.byKey(
      const ValueKey<String>('messaging-group-conversation-conversation:group'),
    );
    expect(agentRow, findsOneWidget);
    expect(groupRow, findsOneWidget);

    await tester.tap(
      find.byKey(const Key('messaging-conversation-filter-groups')),
    );
    await tester.pump();
    expect(agentRow, findsNothing);
    expect(groupRow, findsOneWidget);

    await tester.tap(
      find.byKey(const Key('messaging-conversation-filter-agents')),
    );
    await tester.pump();
    expect(agentRow, findsOneWidget);
    expect(groupRow, findsNothing);

    await tester.tap(
      find.byKey(const Key('messaging-conversation-filter-all')),
    );
    await tester.pump();
    expect(agentRow, findsOneWidget);
    expect(groupRow, findsOneWidget);
  });

  testWidgets(
    'without a presentation scope the contact list keeps the bottom nav '
    'and hides the filters',
    (tester) async {
      await _pumpContacts(tester, sessionsByAgent: const {});

      expect(
        find.byKey(const Key('messaging-conversation-filters')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('messaging-sidebar-bottom-nav')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('messaging-sidebar-title')), findsNothing);
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
  String parentSessionId = '',
  int messageCount = 0,
}) {
  final updatedAt = conversationNow()
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
    parentSessionId: parentSessionId,
    messageCount: messageCount,
  );
}

Future<void> _pumpContacts(
  WidgetTester tester, {
  required Map<String, List<AgentConversationSession>> sessionsByAgent,
  List<TargetCandidate>? targets,
  String selectedAgentId = '',
  String selectedSessionId = '',
  ValueChanged<String>? onSelectAgent,
  void Function(String agentId, String sessionId)? onSelectAgentSession,
  AgentConversationTabActivity activity = AgentConversationTabActivity.none,
  bool Function(AgentConversationSession session)? runningFor,
  bool Function(String targetId)? isPinned,
  ValueChanged<String>? onTogglePinned,
  List<ClientConversationSummary> groupConversations = const [],
  List<ClientConversationSummary> directConversations = const [],
  String selectedGroupConversationId = '',
  ValueChanged<String>? onSelectGroupConversation,
  void Function(String conversationId, bool pinned)?
  onSetGroupConversationPinned,
  ValueChanged<String>? onArchiveGroupConversation,
  VoidCallback? onNewConversation,
  VoidCallback? onSearch,
  VoidCallback? onRefresh,
  bool loading = false,
  bool scanning = false,
  Set<String> loadingAgentIds = const <String>{},
  String loadingGroupConversationId = '',
  VoidCallback? onNewGroupConversation,
  VoidCallback? onNewAgentProfile,
  ValueChanged<String>? onPrefetchSessions,
  ClientSection activeDestination = ClientSection.agents,
  ValueChanged<ClientSection>? onSelectDestination,
  Locale locale = const Locale('en'),
  LayoutAgentsPresentation? presentation,
  MessagingUnreadCursorStore? unreadCursorStore,
  LicoSelectionTreatment? treatment,
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
          child: MessagingFeatureOrderScope(
            orderStore: const _ContactListOrderStore(),
            child: Scaffold(
              body: SizedBox(
                width: 320,
                height: 600,
                child: LayoutDestinationPresentationScope(
                  agents: presentation,
                  child: LicoSelectionTreatmentScope(
                    treatment: treatment ?? LicoSelectionTreatment.lamp,
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
                      selectedSessionId: selectedSessionId,
                      activityFor: (_) => activity,
                      runningFor: runningFor,
                      onSelectAgent: onSelectAgent ?? (_) {},
                      onSelectAgentSession: onSelectAgentSession,
                      onNewConversation: onNewConversation ?? () {},
                      onSearch: onSearch,
                      onRefresh: onRefresh,
                      scanning: scanning,
                      loading: loading,
                      loadingAgentIds: loadingAgentIds,
                      loadingGroupConversationId: loadingGroupConversationId,
                      onNewGroupConversation: onNewGroupConversation,
                      onNewAgentProfile: onNewAgentProfile,
                      groupConversations: groupConversations,
                      directConversations: directConversations,
                      selectedGroupConversationId: selectedGroupConversationId,
                      onSelectGroupConversation: onSelectGroupConversation,
                      onSetGroupConversationPinned:
                          onSetGroupConversationPinned,
                      onArchiveGroupConversation: onArchiveGroupConversation,
                      isPinned: isPinned,
                      onTogglePinned: onTogglePinned,
                      onPrefetchSessions: onPrefetchSessions,
                      activeDestination: activeDestination,
                      onSelectDestination: onSelectDestination,
                      unreadCursorStore: unreadCursorStore,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}
