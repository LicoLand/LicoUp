import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/features/conversations/client_conversation_controller.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/client_conversation_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_process_projection.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_timeline.dart';
import 'package:licoup/src/frontend/features/conversations/canonical_group_conversation_pane.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

void main() {
  test(
    'canonical group events project every typed part with peer identity',
    () {
      final conversation = ClientConversation.fromJson({
        'id': 'conversation:group',
        'title': 'Lico',
        'archived': false,
        'isGroup': true,
        'revision': 4,
        'createdAtUnixMs': 1,
        'updatedAtUnixMs': 20,
        'eventCount': 2,
        'assistantMembershipId': 'membership:codex',
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
            id: 'membership:claude',
            principalId: 'agent:claude-code',
            kind: 'agent',
            label: 'Claude Code',
            agentId: 'claude-code',
          ),
        ],
      });
      final events = [
        ClientConversationEvent.fromJson({
          'id': 'event:agent',
          'conversationId': conversation.id,
          'sequence': 1,
          'authorMembershipId': 'membership:codex',
          'kind': 'message',
          'createdAtUnixMs': 10,
          'finalized': true,
          'parts': [
            _part('part:text', 0, 'text', 'answer'),
            _part('part:reasoning', 1, 'reasoning', 'reasoning'),
            _part('part:tool', 2, 'tool-call', 'tool'),
            _part(
              'part:diagnostic',
              3,
              'diagnostic',
              '{"code":"native_agent_executable_unavailable",'
                  '"stage":"process/launch"}',
            ),
          ],
        }),
        ClientConversationEvent.fromJson({
          'id': 'event:membership',
          'conversationId': conversation.id,
          'sequence': 2,
          'kind': 'membership-changed',
          'createdAtUnixMs': 20,
          'finalized': true,
          'parts': [
            _metadataPart(
              eventId: 'event:membership',
              content:
                  '{"membershipId":"membership:claude",'
                  '"principalId":"agent:claude-code","change":"joined"}',
            ),
          ],
        }),
      ];

      final session = canonicalGroupConversationSession(
        conversation,
        events,
        LicoStrings.forLocale(const Locale('en')),
      );

      expect(session.messages, hasLength(5));
      expect(session.messages[0].participantAgentId, 'codex');
      expect(session.messages[0].participantLabel, 'Codex');
      expect(session.messages[0].participantRole, 'assistant');
      expect(session.messages[0].text, 'answer');
      expect(session.messages[1].cardType, 'reasoning');
      expect(session.messages[2].cardType, 'tool-call');
      expect(session.messages[3].cardType, 'diagnostic');
      expect(
        session.messages[3].text,
        contains('native_agent_executable_unavailable'),
      );
      expect(session.messages[3].text, contains('process/launch'));
      expect(session.messages[4].cardTitle, 'Group membership change');
      expect(session.messages[4].text, 'Added member: Claude Code');
    },
  );

  test('posted image parts project as typed message attachments', () {
    final conversation = ClientConversation.fromJson({
      'id': 'conversation:group',
      'title': 'Lico',
      'archived': false,
      'isGroup': true,
      'revision': 4,
      'createdAtUnixMs': 1,
      'updatedAtUnixMs': 30,
      'eventCount': 3,
      'memberships': [
        _membership(
          id: 'membership:owner',
          principalId: 'human:local',
          kind: 'human',
          label: 'Local User',
          access: 'owner',
        ),
      ],
    });
    Map<String, dynamic> imagePart(
      String eventId,
      String partId,
      int ordinal,
      String content,
    ) => {
      'id': partId,
      'eventId': eventId,
      'ordinal': ordinal,
      'kind': 'image',
      'content': content,
      'createdAtUnixMs': 10,
    };
    final events = [
      // A text-plus-image post: the image lands on the text message.
      ClientConversationEvent.fromJson({
        'id': 'event:with-text',
        'conversationId': conversation.id,
        'sequence': 1,
        'authorMembershipId': 'membership:owner',
        'kind': 'message',
        'createdAtUnixMs': 10,
        'finalized': true,
        'parts': [
          {
            'id': 'part:with-text',
            'eventId': 'event:with-text',
            'ordinal': 0,
            'kind': 'text',
            'content': 'see the mockup',
            'createdAtUnixMs': 10,
          },
          imagePart(
            'event:with-text',
            'part:mockup',
            1,
            '{"path":"fixtures/mockup.png","name":"mockup.png",'
                '"mediaType":"image/png","byteSize":12}',
          ),
        ],
      }),
      // An image-only post: no text part, the images stand alone.
      ClientConversationEvent.fromJson({
        'id': 'event:image-only',
        'conversationId': conversation.id,
        'sequence': 2,
        'authorMembershipId': 'membership:owner',
        'kind': 'message',
        'createdAtUnixMs': 20,
        'finalized': true,
        'parts': [
          imagePart(
            'event:image-only',
            'part:only',
            0,
            '{"path":"fixtures/only.png","name":"only.png",'
                '"mediaType":"image/png","byteSize":7}',
          ),
        ],
      }),
      // Unreadable attachment metadata tolerates the generic card fallback.
      ClientConversationEvent.fromJson({
        'id': 'event:malformed-image',
        'conversationId': conversation.id,
        'sequence': 3,
        'authorMembershipId': 'membership:owner',
        'kind': 'message',
        'createdAtUnixMs': 30,
        'finalized': true,
        'parts': [
          imagePart('event:malformed-image', 'part:broken', 0, 'not-json'),
        ],
      }),
    ];

    final session = canonicalGroupConversationSession(
      conversation,
      events,
      LicoStrings.forLocale(const Locale('en')),
    );

    expect(session.messages, hasLength(3));
    final withText = session.messages[0];
    expect(withText.role, 'user');
    expect(withText.text, 'see the mockup');
    expect(withText.images, hasLength(1));
    expect(withText.images.single.filePath, 'fixtures/mockup.png');
    expect(withText.images.single.name, 'mockup.png');
    expect(withText.images.single.mediaType, 'image/png');

    final imageOnly = session.messages[1];
    expect(imageOnly.role, 'user');
    expect(imageOnly.text, '');
    expect(imageOnly.images.single.filePath, 'fixtures/only.png');

    // The malformed part keeps the honest generic trace instead of
    // vanishing, and no well-formed image leaks its raw metadata JSON.
    final fallback = session.messages[2];
    expect(fallback.cardType, 'event');
    expect(fallback.text, 'not-json');
    expect(
      session.messages.where((message) => message.text.contains('byteSize')),
      isEmpty,
    );
  });

  test('canonical group merges streamed text parts on one event', () {
    final conversation = ClientConversation.fromJson({
      'id': 'conversation:group',
      'title': 'Lico',
      'archived': false,
      'isGroup': true,
      'revision': 4,
      'createdAtUnixMs': 1,
      'updatedAtUnixMs': 20,
      'eventCount': 1,
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
      ],
    });
    final session = canonicalGroupConversationSession(conversation, [
      ClientConversationEvent.fromJson({
        'id': 'event:stream',
        'conversationId': conversation.id,
        'sequence': 1,
        'authorMembershipId': 'membership:codex',
        'kind': 'message',
        'createdAtUnixMs': 10,
        'finalized': false,
        'parts': [
          _part('part:a', 0, 'text', 'Hel'),
          _part('part:b', 1, 'text', 'lo'),
          _part('part:life', 2, 'metadata', '{"lifecycle":"accepted"}'),
        ],
      }),
    ], LicoStrings.forLocale(const Locale('en')));
    expect(session.messages, hasLength(2));
    final reply = session.messages.singleWhere(
      (message) => !message.isStructuredEvent,
    );
    expect(reply.id, 'event:stream');
    expect(reply.role, 'assistant');
    expect(reply.text, 'Hello');
    final lifecycle = session.messages.singleWhere(
      (message) => message.isStructuredEvent,
    );
    expect(lifecycle.cardType, 'lifecycle');
    expect(lifecycle.cardTitle, 'lifecycle.accepted');
  });

  test('canonical group hides an exact legacy completed-text snapshot', () {
    final conversation = ClientConversation.fromJson({
      'id': 'conversation:group',
      'title': 'Lico',
      'archived': false,
      'isGroup': true,
      'revision': 4,
      'createdAtUnixMs': 1,
      'updatedAtUnixMs': 20,
      'eventCount': 1,
      'memberships': [
        _membership(
          id: 'membership:codex',
          principalId: 'agent:codex',
          kind: 'agent',
          label: 'Codex',
          agentId: 'codex',
        ),
      ],
    });
    final session = canonicalGroupConversationSession(conversation, [
      ClientConversationEvent.fromJson({
        'id': 'event:legacy-stream',
        'conversationId': conversation.id,
        'sequence': 1,
        'authorMembershipId': 'membership:codex',
        'kind': 'message',
        'correlationId': 'dispatch:legacy',
        'createdAtUnixMs': 10,
        'finalized': true,
        'parts': [
          _part('part:a', 0, 'text', 'Hel'),
          _part('part:b', 1, 'text', 'lo'),
          _part('part:completed', 2, 'metadata', '{"lifecycle":"completed"}'),
          _part('part:snapshot', 3, 'text', 'Hello'),
        ],
      }),
    ], LicoStrings.forLocale(const Locale('en')));

    expect(
      session.messages
          .where((message) => !message.isStructuredEvent)
          .map((message) => message.text),
      ['Hello'],
    );
  });

  test('canonical group renders each message unit as a separate bubble', () {
    final conversation = ClientConversation.fromJson({
      'id': 'conversation:group',
      'title': 'Lico',
      'archived': false,
      'isGroup': true,
      'revision': 4,
      'createdAtUnixMs': 1,
      'updatedAtUnixMs': 20,
      'eventCount': 1,
      'memberships': [
        _membership(
          id: 'membership:claude',
          principalId: 'agent:claude-code',
          kind: 'agent',
          label: 'Claude Code',
          agentId: 'claude-code',
        ),
      ],
    });
    final session = canonicalGroupConversationSession(conversation, [
      ClientConversationEvent.fromJson({
        'id': 'event:segmented',
        'conversationId': conversation.id,
        'sequence': 1,
        'authorMembershipId': 'membership:claude',
        'kind': 'message',
        'correlationId': 'dispatch:segmented',
        'createdAtUnixMs': 10,
        'finalized': true,
        'parts': [
          _part('part:unit:1', 0, 'metadata', '{"messageUnit":"1"}'),
          _part('part:text:1a', 1, 'text', '第一'),
          _part('part:tool:1', 2, 'tool-call', 'Bash'),
          _part('part:completed:1', 3, 'metadata', '{"lifecycle":"completed"}'),
          _part('part:text:1b', 4, 'text', '段'),
          _part('part:unit:2', 5, 'metadata', '{"messageUnit":"2"}'),
          _part('part:text:2a', 6, 'text', '第二'),
          _part('part:text:2b', 7, 'text', '段'),
        ],
      }),
    ], LicoStrings.forLocale(const Locale('en')));

    expect(
      session.messages
          .where((message) => !message.isStructuredEvent)
          .map((message) => message.text),
      ['第一段', '第二段'],
    );
    final structured = session.messages
        .where((message) => message.isStructuredEvent)
        .toList();
    expect(structured, hasLength(2));
    expect(
      structured.map((message) => message.cardTitle),
      contains('lifecycle.completed'),
    );
  });

  test(
    'canonical group keeps dispatch identity and every persisted operation',
    () {
      final conversation = ClientConversation.fromJson({
        'id': 'conversation:group',
        'title': 'Lico',
        'archived': false,
        'isGroup': true,
        'revision': 4,
        'createdAtUnixMs': 1,
        'updatedAtUnixMs': 20,
        'eventCount': 1,
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
        ],
      });
      final event = ClientConversationEvent.fromJson({
        'id': 'event:stream',
        'conversationId': conversation.id,
        'sequence': 1,
        'authorMembershipId': 'membership:codex',
        'kind': 'message',
        'causationId': 'event:user',
        'correlationId': 'dispatch:one',
        'createdAtUnixMs': 10,
        'finalized': true,
        'parts': [
          _part('part:lifecycle', 0, 'metadata', '{"lifecycle":"processing"}'),
          for (var index = 1; index <= 300; index += 1)
            _part('part:reasoning:$index', index, 'reasoning', 'reasoning'),
          _part('part:tool:1', 301, 'tool-call', 'Bash'),
          _part('part:tool:2', 302, 'tool-call', 'Bash'),
          _part('part:text', 303, 'text', 'done'),
        ],
      });

      expect(event.causationId, 'event:user');
      expect(event.correlationId, 'dispatch:one');
      final session = canonicalGroupConversationSession(conversation, [
        event,
      ], LicoStrings.forLocale(const Locale('en')));
      final process = projectConversationProcessEvents(session.messages);
      expect(process.totalOperations, 303);
      expect(
        session.messages
            .where((message) => message.isStructuredEvent)
            .map((message) => liveTurnKeyOf(message)),
        everyElement('live-dispatch:one'),
      );
    },
  );

  test('canonical group keeps accepted and failed lifecycle parts', () {
    final conversation = ClientConversation.fromJson({
      'id': 'conversation:group',
      'title': 'Lico',
      'archived': false,
      'isGroup': true,
      'revision': 4,
      'createdAtUnixMs': 1,
      'updatedAtUnixMs': 20,
      'eventCount': 1,
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
      ],
    });
    final session = canonicalGroupConversationSession(conversation, [
      ClientConversationEvent.fromJson({
        'id': 'event:agent',
        'conversationId': conversation.id,
        'sequence': 1,
        'authorMembershipId': 'membership:codex',
        'kind': 'message',
        'createdAtUnixMs': 10,
        'finalized': true,
        'parts': [
          _part('part:accepted', 0, 'metadata', '{"lifecycle":"accepted"}'),
          _part(
            'part:diag',
            1,
            'diagnostic',
            '{"code":"codex_turn_not_completed","stage":"turn/completed","turnStatus":"failed/Unauthorized"}',
          ),
          _part('part:failed', 2, 'metadata', '{"lifecycle":"failed"}'),
        ],
      }),
    ], LicoStrings.forLocale(const Locale('en')));
    expect(session.messages.map((message) => message.cardTitle), [
      'lifecycle.accepted',
      '',
      'lifecycle.failed',
    ]);
    expect(session.messages[1].text, contains('failed/Unauthorized'));
  });

  test('canonical group does not translate retired lifecycle aliases', () {
    final conversation = ClientConversation.fromJson({
      'id': 'conversation:group',
      'title': 'Lico',
      'archived': false,
      'isGroup': true,
      'revision': 4,
      'createdAtUnixMs': 1,
      'updatedAtUnixMs': 20,
      'eventCount': 1,
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
      ],
    });
    final session = canonicalGroupConversationSession(conversation, [
      ClientConversationEvent.fromJson({
        'id': 'event:agent',
        'conversationId': conversation.id,
        'sequence': 1,
        'authorMembershipId': 'membership:codex',
        'kind': 'message',
        'createdAtUnixMs': 10,
        'finalized': true,
        'parts': [
          _part('part:running', 0, 'metadata', '{"lifecycle":"running"}'),
          _part('part:cancelled', 1, 'metadata', '{"lifecycle":"cancelled"}'),
        ],
      }),
    ], LicoStrings.forLocale(const Locale('en')));
    expect(session.messages.map((message) => message.cardType), [
      'metadata',
      'metadata',
    ]);
    expect(
      session.messages.map((message) => message.cardTitle),
      everyElement(isEmpty),
    );
  });

  test('canonical group history explains every non-message event', () {
    final conversation = ClientConversation.fromJson({
      'id': 'conversation:group',
      'title': 'Lico',
      'archived': false,
      'isGroup': true,
      'revision': 5,
      'createdAtUnixMs': 1,
      'updatedAtUnixMs': 50,
      'eventCount': 5,
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
      ],
    });
    final events = [
      _domainEvent(
        id: 'event:joined',
        sequence: 1,
        kind: 'membership-changed',
        metadata: '{"membershipId":"membership:codex","change":"joined"}',
      ),
      _domainEvent(
        id: 'event:left',
        sequence: 2,
        kind: 'membership-changed',
        metadata: '{"membershipId":"membership:codex","change":"left"}',
      ),
      _domainEvent(
        id: 'event:access',
        sequence: 3,
        kind: 'membership-changed',
        metadata:
            '{"membershipId":"membership:codex",'
            '"change":"access-set","access":"owner"}',
      ),
      _domainEvent(
        id: 'event:availability',
        sequence: 4,
        kind: 'availability',
        metadata:
            '{"membershipId":"membership:codex",'
            '"availability":"available"}',
      ),
      ClientConversationEvent.fromJson({
        'id': 'event:legacy',
        'conversationId': conversation.id,
        'sequence': 5,
        'kind': 'membership-changed',
        'createdAtUnixMs': 50,
        'finalized': true,
        'parts': <Map<String, dynamic>>[],
      }),
    ];

    final english = canonicalGroupConversationSession(
      conversation,
      events,
      LicoStrings.forLocale(const Locale('en')),
    );
    expect(english.messages.map((message) => message.text), [
      'Added member: Codex',
      'Removed member: Codex',
      'Access changed: Codex → Owner',
      'Availability: Codex → Available',
      'This older record does not include change details',
    ]);

    final chinese = canonicalGroupConversationSession(
      conversation,
      events,
      LicoStrings.forLocale(const Locale('zh', 'CN')),
    );
    expect(chinese.messages.map((message) => message.text), [
      '新增成员：Codex',
      '移除成员：Codex',
      '权限变更：Codex → 群主',
      '可用状态：Codex → 可用',
      '旧记录未保存具体变更',
    ]);
  });

  test('group roster keeps every entry in the queue order', () {
    final conversation = ClientConversation.fromJson({
      'id': 'conversation:group',
      'title': 'Local',
      'archived': false,
      'isGroup': true,
      'revision': 1,
      'createdAtUnixMs': 1,
      'updatedAtUnixMs': 7,
      'eventCount': 7,
      'memberships': [
        _membership(
          id: 'membership:owner',
          principalId: 'human:local',
          kind: 'human',
          label: 'Local User',
          access: 'owner',
        ),
        for (var index = 1; index <= 7; index += 1)
          _membership(
            id: 'membership:agent-$index',
            principalId: 'agent:agent-$index',
            kind: 'agent',
            label: 'Agent $index',
            agentId: 'agent-$index',
          ),
      ],
    });
    final targets = [
      for (var index = 1; index <= 7; index += 1)
        _target('agent-$index', 'Agent $index'),
    ];

    final recent = resolveCanonicalGroupOrderedParticipantTargets(
      conversation,
      targets,
      const ['agent-4', 'agent-7', 'agent-2', 'agent-6', 'agent-1', 'agent-3'],
    );

    expect(recent.map((target) => target.target), [
      'agent-4',
      'agent-7',
      'agent-2',
      'agent-6',
      'agent-1',
      'agent-3',
    ]);
  });

  test('Local roster resolves a newly scanned non-member from queue order', () {
    final conversation = ClientConversation.fromJson({
      'id': 'lico-group-default',
      'title': 'Local',
      'archived': false,
      'isGroup': true,
      'revision': 1,
      'createdAtUnixMs': 1,
      'updatedAtUnixMs': 1,
      'eventCount': 0,
      'memberships': [
        _membership(
          id: 'membership:owner',
          principalId: 'human:local',
          kind: 'human',
          label: 'Local User',
          access: 'owner',
        ),
      ],
    });
    final scannedTarget = _target('new-agent', 'New Agent');

    final recent = resolveCanonicalGroupOrderedParticipantTargets(
      conversation,
      [scannedTarget],
      const ['new-agent'],
    );

    expect(recent, [same(scannedTarget)]);
  });

  testWidgets('restored group header and right-side Agent roster render', (
    tester,
  ) async {
    var rosterToggleCount = 0;
    final mentioned = <String>[];
    final opened = <String>[];
    final conversation = ClientConversation.fromJson({
      'id': 'conversation:group',
      'title': 'Lico',
      'archived': false,
      'pinned': true,
      'isGroup': true,
      'revision': 2,
      'createdAtUnixMs': 1,
      'updatedAtUnixMs': 2,
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
          id: 'membership:claude',
          principalId: 'agent:claude-code',
          kind: 'agent',
          label: 'Claude Code',
          agentId: 'claude-code',
        ),
      ],
    });
    final targets = [
      _target('codex', 'Codex'),
      _target('claude-code', 'Claude Code'),
    ];
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
            child: Column(
              children: [
                CanonicalGroupConversationHeader(
                  conversation: conversation,
                  rosterVisible: true,
                  onToggleRoster: () => rosterToggleCount += 1,
                ),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: CanonicalGroupRoster(
                      conversation: conversation,
                      targets: targets,
                      onMentionAgent: (target) => mentioned.add(target.target),
                      onOpenAgentConversations: (target) =>
                          opened.add(target.target),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Lico'), findsOneWidget);
    expect(find.text('3 members'), findsNothing);
    expect(find.textContaining('@'), findsNothing);
    expect(find.byKey(const Key('canonical-group-archive')), findsNothing);
    expect(
      find.byKey(const Key('canonical-group-roster-toggle')),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.keyboard_arrow_up_rounded), findsOneWidget);
    expect(find.byIcon(Icons.push_pin_rounded), findsOneWidget);
    expect(find.byKey(const Key('canonical-group-roster')), findsOneWidget);
    final headerAvatar = tester.widget<Container>(
      find.byKey(const Key('canonical-group-header-avatar')),
    );
    expect((headerAvatar.decoration! as BoxDecoration).color, Colors.black);
    // The promoted header capsule keeps compact labels alongside each avatar.
    expect(find.text('Codex'), findsOneWidget);
    expect(find.text('Claude'), findsOneWidget);
    expect(find.text('Claude Code'), findsNothing);
    expect(
      tester
          .widgetList<Tooltip>(find.byType(Tooltip))
          .map((tooltip) => tooltip.message),
      containsAll(<String>['Codex', 'Claude Code']),
    );
    await tester.tap(find.byKey(const Key('canonical-group-roster-toggle')));
    await tester.pump();
    expect(rosterToggleCount, 1);

    final codexAvatar = find.byKey(
      const Key('canonical-group-roster-agent-codex'),
    );
    await tester.tap(codexAvatar);
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 1));
    expect(mentioned, ['codex']);

    mentioned.clear();
    await tester.tap(codexAvatar);
    await tester.pump(kDoubleTapMinTime);
    await tester.tap(codexAvatar);
    await tester.pumpAndSettle();
    expect(mentioned, isEmpty);
    expect(opened, ['codex']);

    await tester.tap(codexAvatar, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('canonical-group-roster-menu-codex')),
      findsOneWidget,
    );
    expect(find.text('Mention Codex'), findsOneWidget);
    expect(find.text('Open Codex conversations'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('roster exposes every member inside a five-row viewport', (
    tester,
  ) async {
    final boundaryOverscroll = <double>[];
    final conversation = ClientConversation.fromJson({
      'id': 'conversation:group',
      'title': 'All members',
      'archived': false,
      'isGroup': true,
      'revision': 1,
      'createdAtUnixMs': 1,
      'updatedAtUnixMs': 1,
      'eventCount': 0,
      'memberships': [
        _membership(
          id: 'membership:owner',
          principalId: 'human:local',
          kind: 'human',
          label: 'Local User',
          access: 'owner',
        ),
        for (var index = 1; index <= 7; index += 1)
          _membership(
            id: 'membership:agent-$index',
            principalId: 'agent:agent-$index',
            kind: 'agent',
            label: 'Agent $index',
            agentId: 'agent-$index',
          ),
      ],
    });
    final targets = [
      for (var index = 1; index <= 7; index += 1)
        _target('agent-$index', 'Agent $index'),
    ];

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(platformBrightness: Brightness.dark),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topRight,
            child: SizedBox(
              height: MessagingDesktopMetrics.groupRosterMaxVisibleExtent,
              child: CanonicalGroupRosterSurface(
                child: CanonicalGroupRoster(
                  conversation: conversation,
                  targets: targets,
                  onMentionAgent: (_) {},
                  onBoundaryOverscroll: boundaryOverscroll.add,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      tester
          .getSize(find.byKey(const Key('canonical-group-roster-surface')))
          .height,
      MessagingDesktopMetrics.groupRosterMaxVisibleExtent,
    );
    await tester.drag(
      find.byKey(const Key('canonical-group-roster')),
      const Offset(0, 80),
    );
    await tester.pump();
    expect(boundaryOverscroll, isNotEmpty);
    expect(boundaryOverscroll.any((value) => value < 0), isTrue);
    await tester.scrollUntilVisible(
      find.byKey(const Key('canonical-group-roster-agent-agent-7')),
      120,
      scrollable: find.descendant(
        of: find.byKey(const Key('canonical-group-roster')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(
      find.byKey(const Key('canonical-group-roster-agent-agent-7')),
      findsOneWidget,
    );
  });

  testWidgets('one person and one Agent create a group successfully', (
    tester,
  ) async {
    final runner = _DialogConversationRunner();
    final controller = ClientConversationController(runner: runner);
    final targets = [_target('codex', 'Codex')];
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
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => unawaited(
              showCreateCanonicalGroupConversationDialog(
                context: context,
                controller: controller,
                targets: targets,
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('canonical-group-title-field')),
      'Review room',
    );
    await tester.tap(find.byKey(const Key('canonical-group-member-codex')));
    await tester.pump();

    final confirm = tester.widget<FilledButton>(
      find.byKey(const Key('canonical-group-create-confirm')),
    );
    expect(confirm.onPressed, isNotNull);
    await tester.tap(find.byKey(const Key('canonical-group-create-confirm')));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    runner.completeCreate();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('canonical-group-create-dialog')),
      findsNothing,
    );
    expect(controller.selectedConversationId, 'conversation:created');
  });

  testWidgets('group creation failure remains visible in the dialog', (
    tester,
  ) async {
    final controller = ClientConversationController(
      runner: _FailingDialogConversationRunner(),
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
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => unawaited(
              showCreateCanonicalGroupConversationDialog(
                context: context,
                controller: controller,
                targets: [_target('codex', 'Codex')],
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('canonical-group-title-field')),
      'Review room',
    );
    await tester.tap(find.byKey(const Key('canonical-group-member-codex')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('canonical-group-create-confirm')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('canonical-group-create-dialog')), findsOne);
    expect(find.byKey(const Key('canonical-group-create-failure')), findsOne);
  });
}

final class _DialogConversationRunner implements AgentCommandRunner {
  final _create = Completer<void>();

  void completeCreate() => _create.complete();

  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) async {
    final request = Map<String, dynamic>.from(jsonDecode(stdinText) as Map);
    final action = request['action'];
    if (action == 'conversation.create') await _create.future;
    return {
      'ok': true,
      'result': switch (action) {
        'conversation.create' || 'conversation.get' => {
          'id': 'conversation:created',
          'title': 'Review room',
          'archived': false,
          'isGroup': true,
          'revision': 1,
          'createdAtUnixMs': 1,
          'updatedAtUnixMs': 1,
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
          ],
        },
        'conversation.list' => [
          {
            'id': 'conversation:created',
            'title': 'Review room',
            'archived': false,
            'isGroup': true,
            'revision': 1,
            'updatedAtUnixMs': 1,
            'membershipCount': 2,
            'eventCount': 0,
          },
        ],
        'conversation.events.page' => {
          'events': <Map<String, dynamic>>[],
          'nextCursor': null,
          'totalCount': 0,
        },
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

final class _FailingDialogConversationRunner implements AgentCommandRunner {
  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) async => {
    'ok': false,
    'error': {'code': 'synthetic_create_failed'},
  };

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

Map<String, dynamic> _part(
  String id,
  int ordinal,
  String kind,
  String content,
) => {
  'id': id,
  'eventId': 'event:agent',
  'ordinal': ordinal,
  'kind': kind,
  'content': content,
  'createdAtUnixMs': 10,
};

ClientConversationEvent _domainEvent({
  required String id,
  required int sequence,
  required String kind,
  required String metadata,
}) => ClientConversationEvent.fromJson({
  'id': id,
  'conversationId': 'conversation:group',
  'sequence': sequence,
  'kind': kind,
  'createdAtUnixMs': sequence * 10,
  'finalized': true,
  'parts': [_metadataPart(eventId: id, content: metadata)],
});

Map<String, dynamic> _metadataPart({
  required String eventId,
  required String content,
}) => {
  'id': 'part:$eventId',
  'eventId': eventId,
  'ordinal': 0,
  'kind': 'metadata',
  'content': content,
  'createdAtUnixMs': 10,
};
