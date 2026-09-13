import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_session_state_controller.dart';
import 'fixtures/client_controller/support/fake_agent_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_state_holder.dart';
import 'package:licoup/src/backend/features/agents/services/agent_conversation_service.dart';
import 'package:licoup/src/contracts/conversation_execution.dart';
import 'package:licoup/src/contracts/generated/conversation_protocol.g.dart';
import 'package:licoup/src/platform/native_client/native_conversation_port.dart';

import 'support/fake_conversation_transport.dart';

const _reference = ConversationExecutionReference(
  conversationId: 'conversation-fixture',
  membershipId: 'membership-fixture',
  turnHandle: 'dispatch-fixture',
);

bool _apply(
  ConversationStateHolder holder,
  String kind, {
  String turnId = '',
  Map<String, dynamic> payload = const {},
  ConversationExecutionReference reference = _reference,
}) => holder.applyDelta(
  ConversationDeltaEvent({
    'event': kind,
    'sessionId': 'native-fixture',
    'turnId': turnId,
    ...reference.toJson(),
    'payload': payload,
  }),
  scopeKey: 'scope-fixture',
  participantAgentId: 'agent-fixture',
  participantLabel: 'Fixture Agent',
);

List<AgentConversationMessage> _replies(ConversationStateHolder holder) =>
    holder
        .messagesFor('scope-fixture')
        .where(
          (message) => message.kind == AgentConversationMessageKind.assistant,
        )
        .toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'accepted empty provider turn ID becomes one stable assistant through thinking, first text and terminal',
    () {
      final holder = ConversationStateHolder();
      addTearDown(holder.dispose);
      expect(holder.messagesFor('scope-fixture'), isEmpty);
      _apply(holder, 'agent.turn.accepted');
      final waiting = _replies(holder).single;
      expect(waiting.waitingForReply, isTrue);
      expect(waiting.isDisplayable, isTrue);
      expect(waiting.executionReference, _reference);
      expect(waiting.toJson(), isNot(contains('waitingForReply')));
      _apply(
        holder,
        'agent.turn.processing',
        turnId: 'provider-turn-1',
        payload: {'evidenceKind': 'reasoning', 'text': 'synthetic thinking'},
      );
      expect(_replies(holder).single.waitingForReply, isTrue);
      _apply(
        holder,
        'agent.message.chunk',
        turnId: 'provider-turn-2',
        payload: {'messageUnit': 'native-message-1', 'text': 'body'},
      );
      final first = _replies(holder).single;
      expect(first.id, waiting.id);
      expect(first.waitingForReply, isFalse);
      expect(first.text, 'body');
      _apply(
        holder,
        'agent.message.chunk',
        turnId: 'provider-turn-3',
        payload: {'messageUnit': 'native-message-1', 'text': ' tail'},
      );
      expect(_replies(holder).single.text, 'body tail');
      _apply(
        holder,
        'dispatch.turn.completed',
        payload: {
          'terminalTransition': {'kind': 'lifecycle', 'stage': 'completed'},
        },
      );
      expect(holder.turnStateFor('scope-fixture').active, isFalse);
      expect(_replies(holder).single.id, waiting.id);
      expect(_replies(holder).single.executionReference, _reference);
    },
  );

  test(
    'empty completion, failure, cancellation end waiting; retry is a distinct real dispatch',
    () {
      for (final terminal in [
        'completed',
        'failed',
        'cancelled',
        'interrupted',
      ]) {
        final holder = ConversationStateHolder();
        addTearDown(holder.dispose);
        _apply(
          holder,
          'conversation.user.message',
          payload: {'text': 'synthetic request'},
        );
        expect(_replies(holder).single.waitingForReply, isTrue);
        _apply(
          holder,
          terminal == 'completed'
              ? 'dispatch.turn.completed'
              : 'dispatch.turn.failed',
          payload: {
            'turnState': terminal == 'completed' ? 'succeeded' : terminal,
            'terminalTransition': terminal == 'completed'
                ? {'kind': 'lifecycle', 'stage': 'completed'}
                : {'kind': 'failed', 'code': 'fixture_$terminal'},
          },
        );
        final ended = _replies(holder).single;
        expect(ended.waitingForReply, isFalse, reason: terminal);
        expect(ended.id, 'dispatch-fixture-assistant');
        expect(ended.replyTerminalState?.name, terminal);
        expect(ended.executionReference, _reference);
        expect(ended.toJson(), isNot(contains('replyTerminalState')));
        expect(holder.turnStateFor('scope-fixture').active, isFalse);
        if (terminal != 'completed') {
          expect(
            holder
                .messagesFor('scope-fixture')
                .any((message) => message.text.contains('fixture_$terminal')),
            isTrue,
          );
        }
        const retry = ConversationExecutionReference(
          conversationId: 'conversation-fixture',
          membershipId: 'membership-fixture',
          turnHandle: 'dispatch-retry',
        );
        _apply(holder, 'agent.turn.accepted', reference: retry);
        expect(_replies(holder).single.id, 'dispatch-retry-assistant');
        expect(_replies(holder).single.executionReference, retry);
      }
    },
  );

  test(
    'public failed transport terminal preserves native cancellation status',
    () {
      final holder = ConversationStateHolder();
      addTearDown(holder.dispose);
      _apply(holder, 'agent.turn.accepted');
      _apply(
        holder,
        'dispatch.turn.failed',
        payload: {
          'error': {'turnStatus': 'cancelled', 'code': 'fixture_cancelled'},
          'terminalTransition': {'kind': 'failed', 'code': 'fixture_cancelled'},
        },
      );
      expect(
        _replies(holder).single.replyTerminalState,
        AgentConversationReplyTerminalState.cancelled,
      );
      expect(holder.turnStateFor('scope-fixture').active, isFalse);
    },
  );

  test(
    'another membership cannot overwrite this scope and message references survive parsing and participant defaults',
    () {
      final holder = ConversationStateHolder();
      addTearDown(holder.dispose);
      _apply(holder, 'agent.turn.accepted');
      expect(
        _apply(
          holder,
          'agent.message.chunk',
          reference: const ConversationExecutionReference(
            conversationId: 'conversation-fixture',
            membershipId: 'other-member',
            turnHandle: 'dispatch-fixture',
          ),
          payload: {'text': 'wrong member'},
        ),
        isFalse,
      );
      expect(_replies(holder).single.waitingForReply, isTrue);
      _apply(holder, 'agent.message.chunk', payload: {'text': 'actual body'});
      final parsed = parseAgentConversationMessage(
        _replies(holder).single.toJson(),
      );
      expect(parsed.executionReference, _reference);
      expect(
        parsed
            .withParticipantDefaults(
              agentId: 'fixture',
              label: 'Fixture',
              role: 'member',
            )
            .executionReference,
        _reference,
      );
      final historical = parseAgentConversationMessage({
        'id': 'old-fixture',
        'role': 'assistant',
        'text': 'old body',
      });
      expect(historical.executionReference, isNull);
    },
  );

  test(
    'exact native message revisions retain their explicit execution association',
    () {
      final previous = AgentConversationSession.fromJson({
        'id': 'native-fixture',
        'agentId': 'agent-fixture',
        'nativeSessionId': 'native-fixture',
        'messages': [
          {
            'id': 'message-fixture',
            'role': 'assistant',
            'text': 'body',
            'executionReference': _reference.toJson(),
          },
        ],
      });
      final revision = AgentConversationSession.fromJson({
        'id': 'native-fixture',
        'agentId': 'agent-fixture',
        'nativeSessionId': 'native-fixture',
        'messages': [
          {
            'id': 'message-fixture',
            'role': 'assistant',
            'text': 'body revised',
          },
        ],
      });
      final merged = previous.mergeExactMessagePage(
        revision,
        allowMessageRevisions: true,
      );
      expect(merged.messages.single.text, 'body revised');
      expect(merged.messages.single.executionReference, _reference);
      expect(
        AgentConversationSession.fromJson(
          merged.toJson(),
        ).messages.single.executionReference,
        _reference,
      );
    },
  );

  test(
    'exact message hydration adds its reference without binding equal text from another message',
    () {
      AgentConversationSession session(bool hydrated) =>
          AgentConversationSession.fromJson({
            'id': 'native-fixture',
            'agentId': 'agent-fixture',
            'nativeSessionId': 'native-fixture',
            'messages': [
              {
                'id': 'bound-message',
                'role': 'assistant',
                'text': 'same body',
                if (hydrated) 'executionReference': _reference.toJson(),
              },
              {
                'id': 'unbound-message',
                'role': 'assistant',
                'text': 'same body',
              },
            ],
          });
      final merged = session(false).mergeExactMessagePage(session(true));
      expect(merged.messages.first.executionReference, _reference);
      expect(merged.messages.last.executionReference, isNull);
    },
  );

  test(
    'exact execution readback releases its live scope and includes newer native messages',
    () {
      final controller = ClientController(agentService: FakeAgentService());
      addTearDown(controller.dispose);
      AgentConversationSession session(
        List<Map<String, dynamic>> messages,
        String revision,
      ) => AgentConversationSession.fromJson({
        'id': 'native-fixture',
        'agentId': 'codex',
        'nativeSessionId': 'native-fixture',
        'sourceRevision': revision,
        'messages': messages,
      });
      final previous = session([
        {'id': 'before', 'role': 'user', 'text': 'before'},
      ], 'first');
      controller.selectedConversationAgentId = 'codex';
      controller.conversationSessionsByAgent = {
        'codex': [previous],
      };
      controller.setSelectedConversationSessionId('codex', 'native-fixture');
      final scope = controller.conversationComposerScopeKey;
      for (final kind in [
        'agent.turn.accepted',
        'agent.message.chunk',
        'dispatch.turn.completed',
      ]) {
        controller.conversationApplyDelta(
          scopeKey: scope,
          participantAgentId: 'codex',
          participantLabel: 'Codex',
          event: AgentDispatchEvent(
            kind: kind,
            sessionId: 'native-fixture',
            turnId: 'provider-turn',
            payload: {
              ..._reference.toJson(),
              if (kind == 'agent.message.chunk') 'text': 'live body',
              if (kind == 'dispatch.turn.completed')
                'terminalTransition': {
                  'kind': 'lifecycle',
                  'stage': 'completed',
                },
            },
          ),
        );
      }
      expect(controller.conversationStateHolder.messagesFor(scope), isNotEmpty);
      final incoming = session([
        {'id': 'before', 'role': 'user', 'text': 'before'},
        {
          'id': 'native-reply',
          'role': 'assistant',
          'text': 'provider body with final formatting',
          'executionReference': _reference.toJson(),
        },
        {
          'id': 'external-follow-up',
          'role': 'assistant',
          'text': 'new native message',
        },
      ], 'second');
      controller.conversationCommitCatalog(
        'codex',
        ConversationSessionPage(sessions: [incoming], hasMore: false),
        replaceAll: true,
        updateStatus: false,
      );
      final selected = controller.selectedConversationSession!;
      expect(selected.messages.last.id, 'external-follow-up');
      expect(selected.messages[1].executionReference, _reference);
      expect(controller.conversationStateHolder.messagesFor(scope), isEmpty);
    },
  );

  test(
    'send stream inherits native dispatch context even when provider turn ID arrives late',
    () async {
      final peer = FakeConversationTransport(
        events: (_, _) async* {
          yield {
            'event': 'agent.turn.accepted',
            ..._reference.toJson(),
            'turnId': '',
            'payload': {
              'lifecyclePrefix': ['submitted', 'accepted'],
            },
          };
          yield {
            'event': 'agent.message.chunk',
            'turnId': 'provider-later',
            'payload': {'text': 'body'},
          };
          yield {
            'event': 'done',
            'ok': true,
            'turnId': 'provider-changed',
            'nativeSessionId': 'native-fixture',
          };
        },
      );
      final service = AgentConversationService(
        native: StdioConversationNativePort(
          transport: peer,
          desktopRuntime: true,
        ),
      );
      final events = await service
          .sendStreaming(
            agentId: 'agent-fixture',
            text: 'request',
            sessionId: 'native-fixture',
          )
          .toList();
      expect(events, hasLength(3));
      for (final event in events) {
        expect(
          ConversationExecutionReference.fromJson(event.payload),
          _reference,
        );
      }
    },
  );
}
