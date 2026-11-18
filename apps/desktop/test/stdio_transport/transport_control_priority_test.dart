import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/command_exchange.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/operation_pending_queue.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/read_pool.dart';
import 'package:licoup/src/platform/native_client/native_cli_ports.dart';
import 'package:licoup/src/platform/native_client/native_rpc_priority.dart';

import 'transport_harness.dart';

/// A15 component harness: control commands and the shared read capacity stay
/// bounded while bulk work (a turn backlog, a slow catalog) is outstanding.
void main() {
  test(
    'cancel settling does not wait for a bulk turn backlog, terminal keeps order',
    () async {
      const burstEvents = 6;
      const burstFillerBytes = 2 * 1024 * 1024;
      final filler = _filler(burstFillerBytes);
      late SyntheticNativeRequest sendRequest;
      final context = SyntheticProcessContext((request) {
        switch (request.method) {
          case 'agent.conversation.send':
            sendRequest = request;
            for (var cursor = 1; cursor <= burstEvents; cursor += 1) {
              request.process.sendFrame(
                stdioRpcConversationEvent(
                  requestId: request.id,
                  workflowId: request.workflowId,
                  sequence: cursor,
                  cursor: cursor,
                  turnHandle: 'turn-1',
                  conversationId: 'conversation-1',
                  filler: cursor.isEven ? '$cursor:$filler' : 'small-$cursor',
                ),
              );
            }
          case 'agent.conversation.cancel':
            request.reply({'ok': true, 'status': 'accepted'});
            // The terminal settlement of the turn is written after the control
            // ack and still arrives in stream order.
            request.process.sendFrame(
              stdioRpcConversationTerminal(
                requestId: sendRequest.id,
                workflowId: sendRequest.workflowId,
                sequence: burstEvents + 1,
              ),
            );
          default:
            request.reply(const {});
        }
      });
      final client = NativeStdioRpcClient(processContext: context);
      addTearDown(client.dispose);

      final cursors = <int>[];
      final streamDone = Completer<void>();
      final streamClock = Stopwatch()..start();
      client
          .streamConversation(const {'agent': 'synthetic', 'text': 'probe'})
          .listen((event) {
            if (event['cursor'] is int) cursors.add(event['cursor'] as int);
          }, onDone: streamDone.complete);
      await _waitUntil(() => cursors.isNotEmpty);
      final cancelClock = Stopwatch()..start();
      final cancel = await client
          .executeStructured('agent.conversation.cancel', const {
            'agent': 'synthetic',
            'sessionId': 'session-1',
            'turnId': 'turn-1',
          })
          .timeout(const Duration(seconds: 30));
      cancelClock.stop();
      expect(cancel['ok'], isTrue);
      final cursorsAtAck = List<int>.of(cursors);
      await _waitUntil(
        () => cursors.length == burstEvents,
        timeout: const Duration(seconds: 120),
      );
      streamClock.stop();
      await streamDone.future.timeout(const Duration(seconds: 30));

      expect(
        cursorsAtAck.length,
        lessThan(burstEvents),
        reason: 'the control ack settled while the bulk burst was decoding',
      );
      expect(cursors, [
        for (var cursor = 1; cursor <= burstEvents; cursor += 1) cursor,
      ]);
      expect(context.startCount, 1);
      expect(context.processes.single.killed, isFalse);
      // ignore: avoid_print
      print(
        'V7-F4 control-priority: cancelAckMs=${cancelClock.elapsedMilliseconds} '
        'eventsAtAck=${cursorsAtAck.length}/$burstEvents '
        'burstSettledMs=${streamClock.elapsedMilliseconds}',
      );
      expect(
        cancelClock.elapsedMilliseconds,
        lessThan(streamClock.elapsedMilliseconds),
        reason: 'cancel latency must not track the bulk decode backlog',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'background bulk reads leave the reserved session for foreground work',
    () async {
      final held = <SyntheticNativeRequest>[];
      final context = SyntheticProcessContext((request) {
        final key = request.args.last;
        if (key.startsWith('held-')) {
          held.add(request);
        } else {
          request.reply({'ok': true, 'agent': key});
        }
      });
      final client = NativeStdioRpcClient(processContext: context);
      addTearDown(client.dispose);
      final backgroundToken = RpcPriorityToken(background: true);
      final background = [
        for (var index = 0; index < StdioRpcReadPool.capacity - 1; index += 1)
          runWithRpcPriorityToken(
            backgroundToken,
            () => client.execute([
              'agent-hub',
              'catalog',
              '--agent-id',
              'held-$index',
            ]),
          ),
        runWithRpcPriorityToken(
          backgroundToken,
          () =>
              client.execute(['agent-hub', 'catalog', '--agent-id', 'queued']),
        ),
      ];
      await _waitUntil(
        () => held.length == StdioRpcReadPool.capacity - 1,
        timeout: const Duration(seconds: 10),
      );
      expect(context.startCount, StdioRpcReadPool.capacity - 1);
      expect(
        context.processes
            .expand((process) => process.received)
            .where((frame) => (frame['args'] as List?)?.last == 'queued'),
        isEmpty,
        reason: 'the reserved session is not handed to background work',
      );
      // A foreground read runs on the session the background lane may not take,
      // while the background lane is at its occupancy bound.
      final foreground = await client
          .execute(['agent-hub', 'catalog', '--agent-id', 'foreground'])
          .timeout(const Duration(seconds: 10));
      expect(foreground, {'ok': true, 'agent': 'foreground'});
      for (final request in held) {
        request.reply({'ok': true});
      }
      await Future.wait(background).timeout(const Duration(seconds: 20));
      expect(context.startCount, StdioRpcReadPool.capacity);
      // ignore: avoid_print
      print(
        'V7-F4 capacity-lane: backgroundStarted=${held.length}/${StdioRpcReadPool.capacity} '
        'queuedHeldUntilSlot=true foregroundSettledBeforeRelease=true '
        'sessions=${context.startCount}',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'a cancelled pending bulk read leaves no background slot occupied',
    () async {
      final held = <SyntheticNativeRequest>[];
      final context = SyntheticProcessContext((request) {
        final key = request.args.last;
        if (key.startsWith('held-')) {
          held.add(request);
        } else {
          request.reply({'ok': true, 'agent': key});
        }
      });
      final pool = StdioRpcReadPool(processContext: context);
      var sequence = 0;
      Future<Map<String, dynamic>> read(
        String key, {
        RpcPriorityToken? priority,
        void Function(RpcPendingEntryHandle<StdioRpcReadOperation>)? onEnqueued,
      }) => pool.execute(
        (manager) => executeStdioRpcCommand(
          args: ['agent-hub', 'catalog', '--agent-id', key],
          requestId: 'read-${++sequence}',
          workflowId: 'workflow-v7-f4',
          sessionManager: manager,
        ),
        priority: priority,
        onEnqueued: onEnqueued,
      );
      final backgroundToken = RpcPriorityToken(background: true);
      final background = [
        for (var index = 0; index < StdioRpcReadPool.capacity - 1; index += 1)
          read('held-$index', priority: backgroundToken),
      ];
      await _waitUntil(
        () => held.length == StdioRpcReadPool.capacity - 1,
        timeout: const Duration(seconds: 10),
      );
      RpcPendingEntryHandle<StdioRpcReadOperation>? pending;
      final cancelled = read(
        'queued',
        priority: backgroundToken,
        onEnqueued: (handle) => pending = handle,
      );
      expect(pool.pendingCount, 1);
      expect(pending!.cancel(), isTrue);
      await expectLater(
        cancelled,
        throwsA(
          isA<LicoClientRpcException>().having(
            (error) => error.code,
            'code',
            'cancelled',
          ),
        ),
      );
      expect(pool.pendingCount, 0);
      // The cancelled bulk read never occupied a slot, so the reserved
      // foreground path still runs immediately.
      expect(await read('foreground').timeout(const Duration(seconds: 10)), {
        'ok': true,
        'agent': 'foreground',
      });
      for (final request in held) {
        request.reply({'ok': true});
      }
      await Future.wait(background).timeout(const Duration(seconds: 20));
      await pool.close((manager) => manager.detachAndClose());
      // ignore: avoid_print
      print(
        'V7-F4 cancel-accounting: cancelledPending=true '
        'foregroundSettled=true sessions=${context.startCount}',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

Future<void> _waitUntil(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition not reached');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

String _filler(int length) {
  const unit = 'licoup-v7-f4-transport-payload-';
  final buffer = StringBuffer();
  while (buffer.length < length) {
    buffer.write(unit);
  }
  return buffer.toString().substring(0, length);
}
