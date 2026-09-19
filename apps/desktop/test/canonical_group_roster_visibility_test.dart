import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/client_conversation_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_display_names.dart';
import 'package:licoup/src/frontend/features/agents/ui/conversation/canonical_group_conversation_pane/projection.dart';

void main() {
  test('group roster omits retired adapters and does not synthesize them', () {
    final conversation = ClientConversation.fromJson({
      'id': 'conversation:group',
      'title': 'Lico',
      'archived': false,
      'isGroup': true,
      'revision': 1,
      'createdAtUnixMs': 1,
      'updatedAtUnixMs': 3,
      'eventCount': 0,
      'memberships': [
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
          id: 'membership:kimi-desktop',
          principalId: 'agent:kimi-desktop',
          kind: 'agent',
          label: 'Kimi',
          agentId: 'kimi-desktop',
        ),
        _membership(
          id: 'membership:kimi',
          principalId: 'agent:kimi',
          kind: 'agent',
          label: 'Kimi',
          agentId: 'kimi',
        ),
        _membership(
          id: 'membership:kimi-code',
          principalId: 'agent:kimi-code',
          kind: 'agent',
          label: 'Kimi Code',
          agentId: 'kimi-code',
        ),
        _membership(
          id: 'membership:ghost',
          principalId: 'agent:ghost',
          kind: 'agent',
          label: 'Ghost',
          agentId: 'ghost-adapter',
        ),
      ],
    });
    final kimiCode = _target('kimi-code', 'Kimi Code');
    final staleDesktop = _target('kimi-desktop', 'Kimi Desktop');
    final participants = resolveCanonicalGroupParticipantTargets(conversation, [
      _target('codex', 'Codex'),
      staleDesktop,
      kimiCode,
    ]);

    expect(participants.map((target) => target.target), ['codex', 'kimi-code']);
    expect(
      participants.any((target) => target.status == 'membership-unverified'),
      isFalse,
    );

    final ordered = resolveCanonicalGroupOrderedParticipantTargets(
      conversation,
      [_target('codex', 'Codex'), staleDesktop, kimiCode],
      const ['kimi-desktop', 'codex', 'ghost-adapter', 'kimi-code', 'kimi'],
    );
    expect(ordered.map((target) => target.target), ['codex', 'kimi-code']);
  });

  test('kimi-code uses the human-readable name Kimi Code', () {
    final target = _target('kimi-code', 'Kimi Code - CLI');
    expect(agentProductDisplayName('kimi-code'), 'Kimi Code');
    expect(agentProductDisplayName('kimi-code-cli'), 'Kimi Code');
    expect(agentConversationTargetDisplayName(target), 'Kimi Code');
    expect(agentConversationTargetCompactDisplayName(target), 'Kimi Code');
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
