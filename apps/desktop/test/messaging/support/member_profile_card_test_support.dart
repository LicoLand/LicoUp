import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/client_conversation_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/conversation/canonical_group_conversation_pane/members_panel.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/shared/layout_palette_projection.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

List<TargetCandidate> memberProfileCardTestTargets() => [
  _target('codex', 'Codex'),
];

ClientConversation memberProfileCardTestConversation() =>
    ClientConversation.fromJson({
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

Future<void> pumpMemberProfileCardTestPanel(
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
                conversation: memberProfileCardTestConversation(),
                targets: memberProfileCardTestTargets(),
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
