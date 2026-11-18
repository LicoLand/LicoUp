import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/backend/features/agents/services/agent_conversation_service.dart';
import 'package:licoup/src/contracts/generated/conversation_protocol.g.dart';

import '../../support/fake_conversation_transport.dart';

void registerAgentConversationDispatchScenarios() {
  test(
    'semantic send preserves the exact native message and bind fields',
    () async {
      final peer = _dispatchPeer();
      final service = AgentConversationService(native: peer.native);
      final turn = await service.send(
        agentId: 'codex',
        text: 'Hello Codex',
        sessionId: 'native-session-1',
        bind: const AgentDispatchBind(
          sessionPath: '/fixture/session.jsonl',
          workingDirectory: '/workspace/project',
          binaryPath: '/tools/codex',
          model: 'gpt-5.5',
          reasoningEffort: 'xhigh',
          acceptanceMode: 'dispatch-lane-unified-1',
        ),
      );
      expect(turn.ok, isTrue);
      expect(turn.raw['mode'], 'runtime-adapter');
      expect(
        peer.requests.single.method,
        ConversationProtocolMethod.agentConversationSend,
      );
      expect(peer.requests.single.params, {
        'agent': 'codex',
        'text': 'Hello Codex',
        'streamEvents': true,
        'sessionId': 'native-session-1',
        'sessionPath': '/fixture/session.jsonl',
        'workingDirectory': '/workspace/project',
        'binaryPath': '/tools/codex',
        'model': 'gpt-5.5',
        'reasoningEffort': 'xhigh',
        'acceptanceMode': 'dispatch-lane-unified-1',
        'timeoutMs': 0,
      });
    },
  );

  test('dispatch preserves the exact native failure', () async {
    final peer = FakeConversationTransport(
      events: (_, _) async* {
        yield {
          'event': 'done',
          'ok': false,
          'error': {
            'code': 'native_agent_authentication_required',
            'stage': 'process/authentication',
          },
          'turnStatus': 'failed',
        };
      },
    );
    final turn = await AgentConversationService(
      native: peer.native,
    ).send(agentId: 'claude-code', text: 'attempt execution', sessionId: '');
    expect(turn.ok, isFalse);
    expect(turn.failureCode, 'native_agent_authentication_required');
    expect(turn.raw['error']['stage'], 'process/authentication');
    expect(peer.requests, hasLength(1));
  });

  test(
    'semantic lane covers exact resume, steer, cancel, cleanup and capabilities',
    () async {
      final peer = _dispatchPeer();
      final service = AgentConversationService(native: peer.native);
      final session = await service.openOrResume(
        agentId: 'codex',
        sessionId: 'native-1',
      );
      expect(session.sessionId, 'native-1');
      expect(session.agentId, 'codex');
      expect(
        peer.requests.single.method,
        ConversationProtocolMethod.agentConversationOpen,
      );
      expect(peer.requests.single.params, {
        'agent': 'codex',
        'sessionId': 'native-1',
      });
      final steer = await service.steer(
        agentId: 'codex',
        text: 'Follow up now',
        sessionId: 'native-1',
        turnId: 'turn-1',
      );
      expect(steer.ok, isFalse);
      expect(steer.failureCode, 'dispatch_steer_unsupported');
      expect(
        peer.requests.last.method,
        ConversationProtocolMethod.agentConversationSteer,
      );
      expect(peer.requests.last.params, {
        'agent': 'codex',
        'text': 'Follow up now',
        'sessionId': 'native-1',
        'turnId': 'turn-1',
      });
      final cancel = await service.cancel(
        agentId: 'codex',
        sessionId: 'native-1',
        turnId: 'turn-1',
      );
      expect(cancel.ok, isFalse);
      expect(cancel.failureCode, 'dispatch_cancel_unsupported');
      expect(
        peer.requests.last.method,
        ConversationProtocolMethod.agentConversationCancel,
      );
      expect(peer.requests.last.params, {
        'agent': 'codex',
        'sessionId': 'native-1',
        'turnId': 'turn-1',
      });
      expect(
        (await service.cleanup(agentId: 'codex', sessionId: 'native-1')).ok,
        isTrue,
      );
      expect(
        peer.requests.last.method,
        ConversationProtocolMethod.agentConversationCleanup,
      );
      final caps = await service.capabilities(agentId: 'codex');
      expect(caps.agentId, 'codex');
      expect(caps.exactResume, isTrue);
      expect(caps.interruptSteer, isTrue);
      expect(caps.runtimeProtocol, 'codex-app-server');
      expect(caps.blockerCodes, isEmpty);
    },
  );

  test('dispatch fails closed when exact resume is rejected', () async {
    final peer = FakeConversationTransport(
      command: (_, _) async => {
        'ok': false,
        'error': {'code': 'native_session_not_found'},
      },
    );
    await expectLater(
      AgentConversationService(
        native: peer.native,
      ).openOrResume(agentId: 'codex', sessionId: 'native-1'),
      throwsA(
        isA<AgentDispatchOpenException>().having(
          (error) => error.code,
          'code',
          'native_session_not_found',
        ),
      ),
    );
  });

  test('dispatch rejects empty or changed resume identity', () async {
    for (final response in [
      {'ok': true, 'nativeSessionId': ''},
      {'ok': true, 'nativeSessionId': 'different-session'},
    ]) {
      final peer = FakeConversationTransport(command: (_, _) async => response);
      await expectLater(
        AgentConversationService(
          native: peer.native,
        ).openOrResume(agentId: 'codex', sessionId: 'native-1'),
        throwsA(isA<AgentDispatchOpenException>()),
      );
    }
  });
}

void main() => registerAgentConversationDispatchScenarios();

FakeConversationTransport _dispatchPeer() => FakeConversationTransport(
  command: (method, request) async => switch (method) {
    ConversationProtocolMethod.agentConversationOpen => {
      'ok': true,
      'nativeSessionId': request['sessionId'],
      'sessionId': request['sessionId'],
      'threadId': request['sessionId'],
    },
    ConversationProtocolMethod.agentConversationSteer => {
      'ok': false,
      'status': 'unsupported',
      'error': {'code': 'dispatch_steer_unsupported', 'stage': 'turn/steer'},
    },
    ConversationProtocolMethod.agentConversationCancel => {
      'ok': false,
      'status': 'unsupported',
      'error': {'code': 'dispatch_cancel_unsupported', 'stage': 'turn/cancel'},
    },
    ConversationProtocolMethod.agentConversationCleanup => {
      'ok': true,
      'status': 'cleaned',
    },
    ConversationProtocolMethod.agentConversationCapabilities => {
      'ok': true,
      'agentId': 'codex',
      'laneFamily': 'app-server',
      'runtimeProtocol': 'codex-app-server',
      'blockerCodes': <String>[],
      'capabilities': {
        'streaming': true,
        'exactResume': true,
        'cancel': false,
        'interruptSteer': true,
        'approvals': false,
        'multimodal': false,
        'usageStatus': false,
      },
    },
    _ => throw StateError('unexpected conversation method'),
  },
  events: (_, _) async* {
    yield {
      'event': 'done',
      'ok': true,
      'mode': 'runtime-adapter',
      'adapterId': 'codex',
      'runtimeProtocol': 'codex-app-server',
      'nativeSessionId': 'thread-stream-1',
      'sessionId': 'thread-stream-1',
      'threadId': 'thread-stream-1',
      'turnId': 'turn-1',
      'turnStatus': 'completed',
      'output': 'streamed reply',
    };
  },
);
