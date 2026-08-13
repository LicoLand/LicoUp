import 'dart:convert';

import 'package:licoup/src/backend/features/agents/services/agent_conversation_service.dart';
import 'package:licoup/src/platform/native_client/agent_service.dart';
import 'package:flutter_test/flutter_test.dart';

void registerAgentConversationDispatchScenarios() {
  test(
    'sends messages through AgentDispatchLane stdin JSON contract',
    () async {
      final agentService = _StdinAgentService();
      const service = AgentConversationService();

      final turn = await service.send(
        runner: agentService,
        agentId: 'codex',
        text: 'Hello Codex',
        sessionId: 'native-session-1',
        bind: AgentDispatchBind(
          sessionPath: ['', 'private', 'session.jsonl'].join('/'),
          workingDirectory: '/workspace/project',
          binaryPath: '/tools/codex',
          model: 'gpt-5.5',
          reasoningEffort: 'xhigh',
          acceptanceMode: 'dispatch-lane-unified-1',
        ),
      );

      expect(turn.ok, isTrue);
      expect(turn.raw['mode'], 'runtime-adapter');
      expect(agentService.capturedArgs.single, [
        'agent',
        'conversation',
        'send',
        '--stdin-json',
        'true',
        '--stream-events',
        'true',
      ]);
      expect(jsonDecode(agentService.capturedStdin.single), {
        'agent': 'codex',
        'text': 'Hello Codex',
        'streamEvents': true,
        'sessionId': 'native-session-1',
        'sessionPath': ['', 'private', 'session.jsonl'].join('/'),
        'workingDirectory': '/workspace/project',
        'binaryPath': '/tools/codex',
        'model': 'gpt-5.5',
        'reasoningEffort': 'xhigh',
        'acceptanceMode': 'dispatch-lane-unified-1',
        'timeoutMs': 0,
      });
    },
  );

  test(
    'dispatch lane reaches the backend and preserves its exact failure',
    () async {
      final agentService = _StreamResultAgentService({
        'event': 'done',
        'ok': false,
        'error': {
          'code': 'native_agent_authentication_required',
          'stage': 'process/authentication',
        },
        'turnStatus': 'failed',
      });
      const service = AgentConversationService();

      final turn = await service.send(
        runner: agentService,
        agentId: 'claude-code',
        text: 'attempt execution',
        sessionId: '',
      );

      expect(turn.ok, isFalse);
      expect(turn.failureCode, 'native_agent_authentication_required');
      expect(turn.raw['error']['stage'], 'process/authentication');
      expect(agentService.capturedArgs, hasLength(1));
    },
  );

  test(
    'dispatch lane covers openOrResume stream cancel and capabilities',
    () async {
      final agentService = _StdinAgentService();
      const service = AgentConversationService();

      final session = await service.openOrResume(
        runner: agentService,
        agentId: 'codex',
        sessionId: 'native-1',
      );
      expect(session.sessionId, 'native-1');
      expect(session.agentId, 'codex');
      expect(agentService.capturedArgs.single, [
        'agent',
        'conversation',
        'open',
        '--stdin-json',
        'true',
      ]);
      expect(jsonDecode(agentService.capturedStdin.single), {
        'agent': 'codex',
        'sessionId': 'native-1',
      });

      final events = await service
          .stream(runner: agentService, agentId: 'codex', sessionId: 'native-1')
          .toList();
      expect(events, isNotEmpty);
      expect(events.first.kind, 'dispatch.lane.bound');

      final steer = await service.steer(
        runner: agentService,
        agentId: 'codex',
        text: 'Follow up now',
        sessionId: 'native-1',
        turnId: 'turn-1',
      );
      expect(steer.ok, isFalse);
      expect(steer.failureCode, 'dispatch_steer_unsupported');
      expect(agentService.capturedArgs.last, [
        'agent',
        'conversation',
        'steer',
        '--stdin-json',
        'true',
      ]);
      expect(jsonDecode(agentService.capturedStdin.last), {
        'agent': 'codex',
        'text': 'Follow up now',
        'sessionId': 'native-1',
        'turnId': 'turn-1',
      });

      final cancel = await service.cancel(
        runner: agentService,
        agentId: 'codex',
        sessionId: 'native-1',
        turnId: 'turn-1',
      );
      expect(cancel.ok, isFalse);
      expect(cancel.failureCode, 'dispatch_cancel_unsupported');
      expect(agentService.capturedArgs.last, [
        'agent',
        'conversation',
        'cancel',
        '--stdin-json',
        'true',
      ]);
      expect(jsonDecode(agentService.capturedStdin.last), {
        'agent': 'codex',
        'sessionId': 'native-1',
        'turnId': 'turn-1',
      });

      final cleanup = await service.cleanup(
        runner: agentService,
        agentId: 'codex',
        sessionId: 'native-1',
      );
      expect(cleanup.ok, isTrue);
      expect(agentService.capturedArgs.last, [
        'agent',
        'conversation',
        'cleanup',
        '--stdin-json',
        'true',
      ]);

      final caps = await service.capabilities(
        runner: agentService,
        agentId: 'codex',
      );
      expect(caps.agentId, 'codex');
      expect(caps.exactResume, isTrue);
      expect(caps.interruptSteer, isTrue);
      expect(caps.runtimeProtocol, 'codex-app-server');
      expect(caps.blockerCodes, isEmpty);
    },
  );

  test('dispatch lane fails closed when exact resume is rejected', () async {
    const service = AgentConversationService();
    final runner = _OpenResultAgentService({
      'ok': false,
      'error': {'code': 'native_session_not_found'},
    });

    await expectLater(
      service.openOrResume(
        runner: runner,
        agentId: 'codex',
        sessionId: 'native-1',
      ),
      throwsA(
        isA<AgentDispatchOpenException>().having(
          (error) => error.code,
          'code',
          'native_session_not_found',
        ),
      ),
    );
  });

  test('dispatch lane rejects empty or changed resume identity', () async {
    const service = AgentConversationService();

    for (final response in [
      {'ok': true, 'nativeSessionId': ''},
      {'ok': true, 'nativeSessionId': 'different-session'},
    ]) {
      await expectLater(
        service.openOrResume(
          runner: _OpenResultAgentService(response),
          agentId: 'codex',
          sessionId: 'native-1',
        ),
        throwsA(isA<AgentDispatchOpenException>()),
      );
    }
  });
}

void main() => registerAgentConversationDispatchScenarios();

class _StdinAgentService extends AgentService {
  final List<List<String>> capturedArgs = [];
  final List<String> capturedStdin = [];

  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) async {
    capturedArgs.add(List<String>.from(args));
    capturedStdin.add(stdinText);
    if (args.contains('open')) {
      final request = jsonDecode(stdinText) as Map<String, dynamic>;
      final sessionId = (request['sessionId'] ?? '').toString();
      return {
        'ok': true,
        'nativeSessionId': sessionId,
        'sessionId': sessionId,
        'threadId': sessionId,
      };
    }
    if (args.contains('steer')) {
      return {
        'ok': false,
        'status': 'unsupported',
        'error': {'code': 'dispatch_steer_unsupported', 'stage': 'turn/steer'},
      };
    }
    if (args.contains('cancel')) {
      return {
        'ok': false,
        'status': 'unsupported',
        'error': {
          'code': 'dispatch_cancel_unsupported',
          'stage': 'turn/cancel',
        },
      };
    }
    if (args.contains('cleanup')) {
      return {'ok': true, 'status': 'cleaned'};
    }
    if (args.contains('capabilities')) {
      return {
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
      };
    }
    return {
      'ok': true,
      'mode': 'runtime-adapter',
      'adapterId': 'codex',
      'runtimeProtocol': 'codex-app-server',
    };
  }

  @override
  Stream<Map<String, dynamic>> streamCliJsonLinesWithStdin(
    List<String> args,
    String stdinText,
  ) async* {
    capturedArgs.add(List<String>.from(args));
    capturedStdin.add(stdinText);
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
  }
}

class _OpenResultAgentService extends AgentService {
  _OpenResultAgentService(this.result);

  final Map<String, dynamic> result;

  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) async => result;
}

class _StreamResultAgentService extends AgentService {
  _StreamResultAgentService(this.result);

  final Map<String, dynamic> result;
  final List<List<String>> capturedArgs = [];

  @override
  Stream<Map<String, dynamic>> streamCliJsonLinesWithStdin(
    List<String> args,
    String stdinText,
  ) async* {
    capturedArgs.add(List<String>.from(args));
    yield result;
  }
}
