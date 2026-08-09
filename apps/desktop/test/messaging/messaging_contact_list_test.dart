import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/agent_conversation_tab_activity.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_contact_list.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/agent_brand_icon.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

void main() {
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
    await tester.tap(find.text('Unpin From Top'));
    await tester.pumpAndSettle();

    // The toggle targets the pinned member, not the group representative.
    expect(toggled, ['codex-desktop']);
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
            onNewConversation: () {},
            isPinned: isPinned,
            onTogglePinned: onTogglePinned,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}
