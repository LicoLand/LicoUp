import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/contracts/conversation_native_port.dart';
import 'package:licoup/src/contracts/generated/conversation_protocol.g.dart';
import 'package:licoup/src/platform/native_client/agent_service.dart';
import 'package:licoup/src/platform/native_client/native_cli_ports.dart';
import 'package:licoup/src/platform/native_client/native_conversation_port.dart';

import 'support/fake_conversation_transport.dart';

void main() {
  test(
    'semantic conversations always use structured RPC with an injected CLI executor',
    () async {
      final executor = _CountingExecutor();
      final peer = FakeConversationTransport(
        command: (_, _) async => {'ok': true},
        events: (_, _) async* {
          yield {'event': 'done', 'ok': true};
        },
      );
      final service = AgentService(
        oneShotCommandExecutor: executor,
        stdioRpcTransport: peer,
        persistentStdioRpcEnabled: false,
      );
      addTearDown(service.dispose);
      final native = service.conversationNativePort;
      const session = AgentConversationSessionScope(
        agentId: 'synthetic',
        sessionId: 'native-session',
      );
      await native.open(session);
      await native.send(session, text: 'synthetic content').toList();
      await native.executeClientConversation(
        ClientConversationCommand({
          'action': 'conversation.message.post',
          'conversationId': 'canonical-session',
          'text': 'content',
        }),
      );
      expect(peer.requests.map((request) => request.method), [
        ConversationProtocolMethod.agentConversationOpen,
        ConversationProtocolMethod.agentConversationSend,
        ConversationProtocolMethod.clientConversationExecute,
      ]);
      expect(executor.calls, 0);
    },
  );

  test(
    'generic CLI entry points reject stateful namespaces before starting a process',
    () async {
      for (final persistent in [false, true]) {
        final executor = _CountingExecutor();
        final context = _RejectProcessContext();
        final peer = FakeConversationTransport();
        final service = AgentService(
          processContext: context,
          oneShotCommandExecutor: executor,
          stdioRpcTransport: peer,
          persistentStdioRpcEnabled: persistent,
        );
        addTearDown(service.dispose);
        for (final args in [
          ['agent', 'conversation', 'send'],
          ['agent', 'conversation', 'unregistered'],
          ['conversation', 'execute'],
        ]) {
          final rejected = throwsA(
            isA<LicoClientRpcException>().having(
              (error) => error.code,
              'code',
              'conversation_port_required',
            ),
          );
          await expectLater(service.runCli(args), rejected);
          await expectLater(service.runCliWithStdin(args, '{}'), rejected);
          await expectLater(
            service.streamCliJsonLines(args).toList(),
            rejected,
          );
          await expectLater(
            service.streamCliJsonLinesWithStdin(args, '{}').toList(),
            rejected,
          );
        }
        expect(context.startCount, 0);
        expect(executor.calls, 0);
        expect(peer.requests, isEmpty);
        if (!persistent) expect(await service.runCli(['status']), {'ok': true});
      }
    },
  );

  test('local mobile dispatch cannot open a desktop sidecar', () async {
    final peer = FakeConversationTransport();
    final native = StdioConversationNativePort(
      transport: peer,
      desktopRuntime: false,
    );
    final rejected = throwsA(
      isA<NativeConversationException>().having(
        (error) => error.code,
        'code',
        'local_conversation_runtime_unavailable',
      ),
    );
    await expectLater(
      native.open(const AgentConversationSessionScope(agentId: 'synthetic')),
      rejected,
    );
    await expectLater(
      native
          .send(
            const AgentConversationSessionScope(agentId: 'synthetic'),
            text: 'content',
          )
          .toList(),
      rejected,
    );
    await expectLater(
      native.executeClientConversation(
        ClientConversationCommand({'action': 'conversation.list'}),
      ),
      rejected,
    );
    expect(peer.requests, isEmpty);
  });

  test(
    'platform transport failures have one typed redacted boundary',
    () async {
      final peer = FakeConversationTransport(
        command: (_, _) async =>
            throw const LicoClientRpcException('invalid_response'),
        events: (_, _) async* {
          throw const LicoClientRpcException('transport_failed');
        },
      );
      await expectLater(
        peer.native.open(
          const AgentConversationSessionScope(agentId: 'synthetic'),
        ),
        throwsA(
          isA<NativeConversationException>().having(
            (error) => error.code,
            'code',
            'invalid_response',
          ),
        ),
      );
      await expectLater(
        peer.native
            .send(
              const AgentConversationSessionScope(agentId: 'synthetic'),
              text: 'content',
            )
            .toList(),
        throwsA(
          isA<NativeConversationException>().having(
            (error) => error.code,
            'code',
            'transport_failed',
          ),
        ),
      );
    },
  );

  test(
    'cancelling a semantic observer does not issue native turn cancellation',
    () async {
      final events = StreamController<Map<String, dynamic>>();
      final peer = FakeConversationTransport(events: (_, _) => events.stream);
      final observed = Completer<void>();
      final subscription = peer.native
          .attach(
            const PersistentConversationTurnScope(
              turnHandle: 'turn-1',
              conversationId: 'conversation-1',
            ),
            afterCursor: 5,
          )
          .listen((_) => observed.complete());
      events.add({'event': 'agent.message.chunk', 'cursor': 6});
      await observed.future;
      await subscription.cancel();
      await events.close();
      expect(
        peer.requests.single.method,
        ConversationProtocolMethod.agentConversationAttach,
      );
      expect(peer.requests.single.params, {
        'turnHandle': 'turn-1',
        'conversationId': 'conversation-1',
        'afterCursor': 5,
      });
    },
  );
}

final class _CountingExecutor implements NativeCommandExecutor {
  int calls = 0;
  @override
  Future<Map<String, dynamic>> execute(List<String> arguments) async {
    calls++;
    return {'ok': true};
  }
}

final class _RejectProcessContext implements NativeCliProcessContext {
  int startCount = 0;
  @override
  Duration get requestTimeout => const Duration(seconds: 1);
  @override
  Future<Map<String, String>?> buildEnvironment() async => null;
  @override
  Future<File?> resolveCliBinary() async => null;
  @override
  Future<Process> startProcess(
    String executable,
    List<String> arguments,
    Map<String, String>? environment, {
    ProcessStartMode mode = ProcessStartMode.normal,
  }) async {
    startCount++;
    throw StateError('synthetic fixture must not start a process');
  }
}
