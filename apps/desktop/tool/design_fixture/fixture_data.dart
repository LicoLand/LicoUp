/// Synthetic presentation data for the design-alignment fixture.
///
/// Every value is fabricated for visual comparison against the approved
/// interactive design lab; nothing here is a real user, agent or transcript.
library;

import 'dart:io';

import 'package:licoup/src/contracts/target_candidate.dart';

var _fixtureSeq = 0;

String _synth(String label) => '$label-${_fixtureSeq++}';


/// Design-bench home under the OS temp dir (no machine-absolute literal).
String get fixtureHome => '${Directory.systemTemp.path}/licoup-design-home';
const String fixtureGroupId = 'lico-group-default';
const int _now = 1792000000000;

/// The demo roster: the resident assistant plus the five installed agents.
const List<({String id, String label})> fixtureAgents = [
  (id: 'lico-agent', label: 'Lico Agent'),
  (id: 'claude-code', label: 'Claude Code'),
  (id: 'codex', label: 'Codex'),
  (id: 'cursor', label: 'Cursor'),
  (id: 'kimi-code', label: 'Kimi Code'),
  (id: 'opencode', label: 'OpenCode'),
];

/// `agent-hub catalog` result: the roster installed plus two uninstalled
/// products so Agent Hub renders real tiles in the bench.
Map<String, dynamic> fixtureAgentHubCatalog() => {
  'ok': true,
  'scanGeneration': 1,
  'cards': [
    for (final agent in fixtureAgents)
      {
        'id': agent.id,
        'label': agent.label,
        'adaptation': 'deep',
        'present': true,
        'ownership': 'licoup',
        'lifecycle': 'installed',
        'primaryAction': 'open',
        'installable': true,
        'selectedChannelKind': 'cli',
        'channelKind': 'cli',
        'summary': 'Design-fixture ${agent.label} integration.',
        'homepage': 'https://licoup.example/agents/${agent.id}',
        'installedVersion': '1.4.0',
        'latestVersion': '1.4.0',
        'updateAvailable': false,
        'version': '1.4.0',
        'installKinds': const ['cli'],
        'installChannels': const [
          {
            'id': 'cli',
            'kind': 'cli',
            'versionPolicy': 'latest',
            'officialSource': 'fixture',
          },
        ],
      },
    {
      'id': 'gemini-cli',
      'label': 'Gemini CLI',
      'adaptation': 'partial',
      'present': false,
      'ownership': 'none',
      'lifecycle': 'absent',
      'primaryAction': 'install',
      'installable': true,
      'selectedChannelKind': '',
      'channelKind': 'cli',
      'summary': 'Google Gemini command-line agent.',
      'homepage': 'https://licoup.example/agents/gemini-cli',
      'installedVersion': '',
      'latestVersion': '0.9.1',
      'updateAvailable': false,
      'version': '0.9.1',
      'installKinds': const ['cli'],
      'installChannels': const [
        {
          'id': 'cli',
          'kind': 'cli',
          'versionPolicy': 'latest',
          'officialSource': 'fixture',
        },
      ],
    },
  ],
};

List<TargetCandidate> fixtureTargets() => [
  for (final agent in fixtureAgents)
    TargetCandidate(
      id: agent.id,
      target: agent.id,
      label: agent.label,
      kind: 'cli',
      status: 'detected',
      configured: true,
      confidence: 1,
      binaryPath: '/fixture-bin/${agent.id}',
      adapterStatus: 'implemented',
      adapterCapabilities: const {
        'conversationDriver': 'implemented',
        'conversationProtocol': 'design-fixture',
        'conversationReadiness': 'ready',
      },
      supportedActions: const ['runtime.message.send'],
    ),
];

Map<String, dynamic> _principal({
  required String id,
  required String kind,
  required String displayName,
  String agentId = '',
}) => {
  'id': id,
  'kind': kind,
  'displayName': displayName,
  'agentId': agentId,
  'createdAtUnixMs': _now - 86400000,
};

Map<String, dynamic> _membership(
  String id, {
  required Map<String, dynamic> principal,
  String access = 'member',
}) => {
  'id': id,
  'conversationId': fixtureGroupId,
  'principal': principal,
  'access': access,
  'status': 'active',
  'joinedAtUnixMs': _now - 86400000,
};

/// Membership ids used as event authors: the human owner, then one per agent
/// in [fixtureAgents] order.
const String ownerMembershipId = 'm-owner';
String agentMembershipId(String agentId) => 'm-$agentId';

List<Map<String, dynamic>> fixtureMemberships() => [
  _membership(
    ownerMembershipId,
    principal: _principal(id: 'human:local', kind: 'human', displayName: 'You'),
    access: 'owner',
  ),
  for (final agent in fixtureAgents)
    _membership(
      agentMembershipId(agent.id),
      principal: _principal(
        id: 'agent:${agent.id}',
        kind: 'agent',
        displayName: agent.label,
        agentId: agent.id,
      ),
    ),
];

/// `conversation.list` result: one pinned local group holding the roster.
List<Map<String, dynamic>> fixtureConversationList() => [
  {
    'id': fixtureGroupId,
    'title': 'Design review crew',
    'archived': false,
    'pinned': true,
    'isGroup': true,
    'revision': 3,
    'updatedAtUnixMs': _now,
    'membershipCount': fixtureAgents.length + 1,
    'eventCount': fixtureGroupEvents.length,
    'memberAgentIds': [for (final agent in fixtureAgents) agent.id],
    'hasLocalOwner': true,
  },
];

/// `conversation.get` result for the group.
Map<String, dynamic> fixtureConversationGet() => {
  'id': fixtureGroupId,
  'title': 'Design review crew',
  'archived': false,
  'pinned': true,
  'isGroup': true,
  'strategyRevision': 'rev-1',
  'assistantMembershipId': agentMembershipId('lico-agent'),
  'revision': 3,
  'createdAtUnixMs': _now - 86400000,
  'updatedAtUnixMs': _now,
  'memberships': fixtureMemberships(),
  'eventCount': fixtureGroupEvents.length,
  'nativeSessionReferences': const <Object>[],
  'taskViews': const <Object>[],
};

Map<String, dynamic> _textEvent(
  int sequence,
  String authorMembershipId,
  String text,
) => {
  'id': 'ev-$sequence',
  'conversationId': fixtureGroupId,
  'sequence': sequence,
  'authorMembershipId': authorMembershipId,
  'kind': 'message',
  'createdAtUnixMs': _now - (fixtureGroupEventsTotal - sequence) * 60000,
  'finalized': true,
  'parts': [
    {
      'id': 'ev-$sequence-p1',
      'eventId': 'ev-$sequence',
      'ordinal': 0,
      'kind': 'text',
      'content': text,
      'createdAtUnixMs': _now - (fixtureGroupEventsTotal - sequence) * 60000,
    },
  ],
};

const int fixtureGroupEventsTotal = 8;

/// Mixed user/agent transcript including the `[sticker:…]` inline message.
final List<Map<String, dynamic>> fixtureGroupEvents = [
  _textEvent(
    1,
    ownerMembershipId,
    'Team, compare the Dashboard rail and the Desktop work area against the '
    'design lab and report anything off-spec.',
  ),
  _textEvent(
    2,
    agentMembershipId('lico-agent'),
    'On it — I will walk the rail tokens and the title row first.',
  ),
  _textEvent(
    3,
    agentMembershipId('claude-code'),
    'The rail currently measures 88px; the approved spec pins it at 72px '
    'with a 40px avatar and 44px buttons.',
  ),
  _textEvent(4, ownerMembershipId, '[sticker:lico-celebrate]'),
  _textEvent(
    5,
    agentMembershipId('codex'),
    'Drafted the token revert: rail 72, avatar 40, buttons 44 radius 14, '
    'icons 22.',
  ),
  _textEvent(
    6,
    agentMembershipId('kimi-code'),
    'Cross-checking the Desktop dock while the collaboration run replans '
    'the index task.',
  ),
  // A short owner message late in the transcript keeps the lavender user
  // bubble on the first screen for design review; an agent reply follows.
  _textEvent(7, ownerMembershipId, 'Looks right — proceed with the rail fix.'),
  _textEvent(
    8,
    agentMembershipId('opencode'),
    'Agent Hub tiles are consistent with the demo roster.',
  ),
];

/// `conversation.events.page` result for the group.
Map<String, dynamic> fixtureEventPage() => {
  'events': fixtureGroupEvents,
  'nextCursor': '',
  'totalCount': fixtureGroupEvents.length,
  'hasEarlier': false,
};

/// `conversation.active` result: one running turn and one turn parked on a
/// human decision, so the roster shows working and needs-approval states.
Map<String, dynamic> fixtureActiveTurns() => {
  'ok': true,
  'turns': [
    {
      'turnHandle': 'turn-cursor-decision',
      'conversationId': fixtureGroupId,
      'membershipId': agentMembershipId('cursor'),
      'agentId': 'cursor',
    },
    {
      'turnHandle': 'turn-kimi-running',
      'conversationId': fixtureGroupId,
      'membershipId': agentMembershipId('kimi-code'),
      'agentId': 'kimi-code',
    },
  ],
};

/// First frames for each attached turn. The streams stay open afterwards so
/// the turns remain live; the waiting-for-human state is the demo's
/// "waiting decision".
List<Map<String, dynamic>> fixtureAttachFrames(String turnHandle) =>
    switch (turnHandle) {
      'turn-cursor-decision' => [
        {
          'event': 'agent.turn.processing',
          'cursor': 1,
          'turnHandle': turnHandle,
          'conversationId': fixtureGroupId,
          'membershipId': agentMembershipId('cursor'),
          'payload': {
            'evidenceKind': 'reasoning',
            'text': 'Re-checking the title row against the demo.',
          },
        },
        {
          'event': 'agent.approval.needed',
          'cursor': 2,
          'turnHandle': turnHandle,
          'conversationId': fixtureGroupId,
          'membershipId': agentMembershipId('cursor'),
          'sessionId': 'fixture-session-cursor',
          'turnId': 'turn-cursor-decision',
          'payload': {
            'turnState': {
              'state': 'waiting-for-human',
              'inputEnabled': true,
              'cancelEnabled': true,
            },
            'agentId': 'cursor',
            'adapterCallbackTokenRef': _synth('fixture-cursor-callback-token'),
            'pendingOperationId': 'fixture-cursor-approval-1',
            'displaySummary': 'Approve the Desktop title-row change',
            'requestedTools': ['edit'],
          },
        },
      ],
      'turn-kimi-running' => [
        {
          'event': 'agent.turn.processing',
          'cursor': 1,
          'turnHandle': turnHandle,
          'conversationId': fixtureGroupId,
          'membershipId': agentMembershipId('kimi-code'),
          'payload': {
            'turnState': {'state': 'running'},
            'evidenceKind': 'tool',
            'toolName': 'layout-measure',
            'text': 'Measuring dock hit targets.',
          },
        },
      ],
      _ => const [],
    };
