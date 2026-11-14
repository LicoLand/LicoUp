import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/client_conversation_models.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/contracts/agent_conversation_tab_activity.dart';
import 'package:licoup/src/frontend/features/agents/ui/conversation/canonical_group_conversation_pane/members_panel.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_contact_list.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/shared/layout_palette_projection.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

void main() {
  final conversation = ClientConversation.fromJson({
    'id': 'conversation:group',
    'title': 'Local',
    'isGroup': true,
    'assistantMembershipId': 'membership:codex',
    'memberships': [
      _membership(
        id: 'membership:self',
        principalId: 'human:local',
        kind: 'human',
        label: '小芋',
        access: 'owner',
      ),
      _membership(
        id: 'membership:codex',
        principalId: 'agent:codex',
        kind: 'agent',
        label: 'Codex',
        agentId: 'codex',
      ),
    ],
  });

  final targets = [_target('codex', 'Codex')];

  Future<void> pumpPanel(
    WidgetTester tester, {
    ValueChanged<TargetCandidate>? onMentionAgent,
    void Function(TargetCandidate, Offset)? onOpenMemberHistory,
    VoidCallback? onOpenSettings,
    ValueChanged<String>? onSelfMascotChanged,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 700);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
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
              body: Align(
                alignment: Alignment.centerRight,
                child: CanonicalGroupMembersPanel(
                  conversation: conversation,
                  targets: targets,
                  turnPhases: const {},
                  onMentionAgent: onMentionAgent ?? (_) {},
                  onOpenMemberHistory: onOpenMemberHistory,
                  onOpenSettings: onOpenSettings,
                  onSelfMascotChanged: onSelfMascotChanged,
                  memberSessionCounts: const {'codex': 3},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('tapping an agent member opens its profile card', (tester) async {
    final opened = <String>[];
    final mentioned = <String>[];
    await pumpPanel(
      tester,
      onMentionAgent: (target) => mentioned.add(target.target),
      onOpenMemberHistory: (target, _) => opened.add(target.target),
    );
    await tester.tap(find.byKey(const Key('canonical-group-member-codex')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('member-profile-card-codex')), findsOneWidget);
    expect(find.text('发消息'), findsOneWidget);
    expect(find.text('提及'), findsOneWidget);
    expect(find.text('3'), findsWidgets);

    await tester.tap(find.text('提及'));
    await tester.pumpAndSettle();
    expect(mentioned, ['codex']);
    expect(find.byKey(const Key('member-profile-card-codex')), findsNothing);
    expect(opened, isEmpty);
  });

  testWidgets('the card 发消息 action forwards to member history', (tester) async {
    final opened = <String>[];
    await pumpPanel(
      tester,
      onOpenMemberHistory: (target, _) => opened.add(target.target),
    );
    await tester.tap(find.byKey(const Key('canonical-group-member-codex')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('发消息'));
    await tester.pumpAndSettle();
    expect(opened, ['codex']);
  });

  testWidgets('tapping self opens the self card with identity rows', (
    tester,
  ) async {
    var settingsOpened = false;
    await pumpPanel(
      tester,
      onOpenSettings: () => settingsOpened = true,
      onSelfMascotChanged: (_) {},
    );
    await tester.tap(find.byKey(const Key('canonical-group-member-self')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('member-profile-card-self')), findsOneWidget);
    expect(find.text('小芋'), findsWidgets);
    expect(find.text('在线'), findsWidgets);
    expect(find.textContaining('设备'), findsOneWidget);
    expect(find.text('编辑资料'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(settingsOpened, isTrue);
  });

  Future<void> pumpContactList(
    WidgetTester tester, {
    ValueChanged<String>? onSelectAgent,
    ValueChanged<String>? onSelectGroupConversation,
    ValueChanged<ClientSection>? onSelectDestination,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 700);
    addTearDown(tester.view.reset);
    final groups = [
      for (var i = 0; i < 4; i++)
        ClientConversationSummary.fromJson({
          'id': 'conversation:filler-$i',
          'title': 'Filler $i',
          'isGroup': true,
          'membershipCount': 2,
          'updatedAtUnixMs': 200 - i,
        }),
      ClientConversationSummary.fromJson({
        'id': 'conversation:squad',
        'title': '本地小队',
        'isGroup': true,
        'membershipCount': 4,
        'updatedAtUnixMs': 10,
      }),
    ];
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
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
                width: 300,
                child: MessagingContactList(
                  targets: targets,
                  sessionsByAgent: const {},
                  selectedAgentId: '',
                  activityFor: (_) => AgentConversationTabActivity.none,
                  onSelectAgent: onSelectAgent ?? (_) {},
                  onNewConversation: () {},
                  groupConversations: groups,
                  onSelectGroupConversation: onSelectGroupConversation,
                  onSelectDestination: onSelectDestination,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('contact-row avatar opens the agent card to its right', (
    tester,
  ) async {
    final selected = <String>[];
    await pumpContactList(
      tester,
      onSelectAgent: selected.add,
      onSelectDestination: (_) {},
    );
    final avatar = find.byKey(const Key('messaging-contact-avatar-codex'));
    await tester.tap(avatar);
    await tester.pumpAndSettle();

    final card = find.byKey(const Key('member-profile-card-codex'));
    expect(card, findsOneWidget);
    expect(find.text('发消息'), findsOneWidget);
    expect(find.text('详情 →'), findsOneWidget);
    expect(selected, isEmpty);

    final cardLeft = tester.getTopLeft(card).dx;
    final avatarRight = tester.getTopRight(avatar).dx;
    expect(cardLeft, greaterThanOrEqualTo(avatarRight));

    await tester.tap(find.text('发消息'));
    await tester.pumpAndSettle();
    expect(selected, ['codex']);
  });

  testWidgets('group-row avatar opens the group card to its right', (
    tester,
  ) async {
    final selected = <String>[];
    await pumpContactList(
      tester,
      onSelectGroupConversation: selected.add,
      onSelectDestination: (_) {},
    );
    final avatar = find.byKey(
      const Key('messaging-group-avatar-conversation:squad'),
    );
    await tester.tap(avatar);
    await tester.pumpAndSettle();

    final card = find.byKey(const Key('member-profile-card-group'));
    expect(card, findsOneWidget);
    expect(
      find.descendant(of: card, matching: find.text('本地小队')),
      findsOneWidget,
    );
    expect(find.text('成员 · 4'), findsWidgets);
    expect(selected, isEmpty);
    expect(
      tester.getTopLeft(card).dx,
      greaterThanOrEqualTo(tester.getTopRight(avatar).dx),
    );

    await tester.tap(find.text('成员'));
    await tester.pumpAndSettle();
    expect(selected, ['conversation:squad']);
  });

  testWidgets('member profile card matches the demo anatomy', (tester) async {
    await pumpPanel(
      tester,
      onOpenMemberHistory: (_, _) {},
      onSelfMascotChanged: (_) {},
      onOpenSettings: () {},
    );
    await tester.tap(find.byKey(const Key('canonical-group-member-codex')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byKey(const Key('member-profile-card-codex')),
      matchesGoldenFile('goldens/member_profile_agent.png'),
    );
    // Dismiss and open the self card for its own golden.
    await tester.tapAt(const Offset(60, 350));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('canonical-group-member-self')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑资料'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byKey(const Key('member-profile-card-self')),
      matchesGoldenFile('goldens/member_profile_self.png'),
    );
  });

  testWidgets('编辑资料 reveals the mascot picker and reports picks', (
    tester,
  ) async {
    String? mascot;
    await pumpPanel(tester, onSelfMascotChanged: (id) => mascot = id);
    await tester.tap(find.byKey(const Key('canonical-group-member-self')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('messaging-mascot-pick-luna')), findsNothing);
    await tester.tap(find.text('编辑资料'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('messaging-mascot-pick-luna')), findsOneWidget);
    await tester.tap(find.byKey(const Key('messaging-mascot-pick-luna')));
    await tester.pump();
    expect(mascot, 'luna');
  });
}

TargetCandidate _target(String id, String label) => TargetCandidate(
  target: id,
  label: label,
  kind: 'cli',
  status: 'detected',
  configured: true,
  confidence: 1,
  binaryPath: '/synthetic/bin',
  adapterStatus: 'implemented',
  adapterCapabilities: const {'conversationDriver': 'native'},
  supportedActions: const ['mention', 'relay'],
);

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
