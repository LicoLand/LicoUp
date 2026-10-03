import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/contracts/generated/conversation_protocol.g.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/protocol.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/request_writer.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/response_codec.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/session.dart';

import 'transport_fixture.dart';

/// Real native-child fixture: an executable child writes the bulk frames on a
/// real stdout pipe, the transport under test frames those bytes, and the child
/// itself is the producer that must experience backpressure.
void main() {
  test(
    'a native child control acknowledgement settles while its bulk backlog is held',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-stdio-child-control-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final fixture = await NativeChildFixture.create(directory: directory);
      final context = NativeChildProcessContext(fixture);
      final client = NativeStdioRpcClient(processContext: context);
      addTearDown(client.dispose);

      final burst = _BurstCollector(fixture);
      final terminal = Completer<void>();
      client
          .streamConversation(const {
            'agent': 'synthetic',
            'text': 'synthetic bulk probe',
            'conversationId': 'conversation-1',
          })
          .listen(
            (event) {
              if (event['event'] == 'done') {
                burst.terminalSeen = true;
                burst.terminalOk = event['ok'] == true;
                if (!terminal.isCompleted) terminal.complete();
                return;
              }
              burst.acceptEvent(event);
            },
            onError: (Object error, StackTrace stackTrace) {
              if (!terminal.isCompleted) {
                terminal.completeError(error, stackTrace);
              }
            },
            onDone: () {
              if (!terminal.isCompleted) terminal.complete();
            },
          );

      await _waitUntil(
        () => burst.receivedCursors.isNotEmpty,
        timeout: const Duration(seconds: 60),
      );
      // The cancel travels through the real client control owner while the
      // child's burst is still on the wire and inside the framed backlog.
      final cancelClock = Stopwatch()..start();
      final cancel = await client
          .executeStructured('agent.conversation.cancel', const {
            'agent': 'synthetic',
            'sessionId': 'session-1',
            'turnId': 'turn-1',
          })
          .timeout(const Duration(seconds: 120));
      cancelClock.stop();
      expect(cancel, {'ok': true, 'status': 'accepted'});
      final deliveredAtAck = List<int>.of(burst.receivedCursors);
      expect(
        deliveredAtAck.length,
        lessThan(fixture.framesBeforeControl),
        reason:
            'the control acknowledgement settled while bulk frames written '
            'before it were still inside the framed backlog',
      );
      expect(deliveredAtAck, [
        for (var cursor = 1; cursor <= deliveredAtAck.length; cursor += 1)
          cursor,
      ], reason: 'bulk events keep per-stream order');
      expect(
        burst.mismatchedCursors,
        isEmpty,
        reason: 'every delivered bulk payload is exact',
      );
      expect(
        fixture.burstCompleted,
        isFalse,
        reason: 'the release phase follows its control request',
      );

      await terminal.future.timeout(const Duration(minutes: 3));
      expect(burst.terminalSeen, isTrue);
      expect(
        burst.terminalOk,
        isTrue,
        reason: 'the terminal is the child result, not an invented one',
      );
      expect(
        burst.receivedCursors,
        [
          for (var cursor = 1; cursor <= fixture.burstFrames; cursor += 1)
            cursor,
        ],
        reason: 'every bulk frame is delivered exactly once and in order',
      );
      expect(burst.mismatchedCursors, isEmpty);
      expect(
        burst.receivedPayloadChars,
        fixture.expectedPayloadChars,
        reason: 'the final text is exactly the child payload',
      );
      expect(fixture.burstCompleted, isTrue);
      expect(
        fixture.writtenFrames(),
        [
          for (var cursor = 1; cursor <= fixture.burstFrames; cursor += 1)
            cursor,
        ],
        reason: 'the child finished every frame once capacity was released',
      );
      expect(context.startCount, 1);
      // ignore: avoid_print
      print(
        'stdio-flow-control native-child control-lane: '
        'cancelAckMs=${cancelClock.elapsedMilliseconds} '
        'deliveredAtAck=${deliveredAtAck.length}/${fixture.framesBeforeControl} '
        'burstFrames=${fixture.burstFrames} '
        'payloadBytes=${fixture.expectedPayloadChars}',
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'a native child bulk burst stays inside the declared backlog and stalls the producer',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-stdio-child-bound-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final fixture = await NativeChildFixture.create(
        directory: directory,
        holdForControl: false,
      );
      final process = await fixture.start();
      final session = StdioRpcSession(process);
      addTearDown(() async {
        await session.close(kill: true);
        await process.exitCode.timeout(
          const Duration(seconds: 5),
          onTimeout: () => -1,
        );
      });

      final burst = _BurstCollector(fixture);
      final terminal = Completer<void>();
      session
          .expectConversationFrames(
            requestId: NativeChildFixture.requestId,
            workflowId: NativeChildFixture.workflowId,
          )
          .listen(
            (frame) {
              if (frame is StdioRpcConversationTerminal) {
                burst.terminalSeen = true;
                burst.terminalOk = frame.result != null;
                if (!terminal.isCompleted) terminal.complete();
                return;
              }
              burst.acceptEvent((frame as StdioRpcConversationEvent).event);
            },
            onError: (Object error, StackTrace stackTrace) {
              if (!terminal.isCompleted) {
                terminal.completeError(error, stackTrace);
              }
            },
            onDone: () {
              if (!terminal.isCompleted) terminal.complete();
            },
          );
      await writeStdioRpcFrame(
        session,
        ConversationCommand(
          id: NativeChildFixture.requestId,
          workflowId: NativeChildFixture.workflowId,
          method: ConversationProtocolMethod.agentConversationSend,
          params: const {
            'agent': 'synthetic',
            'text': 'synthetic bulk probe',
            'conversationId': 'conversation-1',
          },
        ).encode(),
      );

      // The child writes faster than the single bulk decode lane drains, so the
      // framed backlog must reach its watermark and pause stdout. Sampling the
      // pause is what makes the producer's own stall observable: a paused
      // transport reads nothing, so the child cannot finish its burst.
      await _waitUntil(
        () => session.decodeBackpressureApplied,
        timeout: const Duration(seconds: 180),
      );
      final writtenWhilePaused = fixture.writtenFrames();
      final pendingWhilePaused = session.pendingDecodeBytes;
      expect(
        writtenWhilePaused.length,
        lessThan(fixture.burstFrames),
        reason:
            'the paused pipe stalled the producer before it wrote the burst',
      );
      expect(fixture.burstCompleted, isFalse);
      expect(
        pendingWhilePaused,
        greaterThan(0),
        reason: 'the framed backlog is held while stdout is paused',
      );
      final backlogBound =
          stdioRpcMaxDecodeBacklogBytes + fixture.frameWireBytes + 64 * 1024;
      expect(
        pendingWhilePaused,
        lessThanOrEqualTo(backlogBound),
        reason: 'framed-but-undispatched bytes stay inside the declared bound',
      );
      expect(
        session.maxObservedDecodeBacklogBytes,
        greaterThanOrEqualTo(stdioRpcMaxDecodeBacklogBytes),
        reason: 'the watermark was reached before stdout was paused',
      );

      await terminal.future.timeout(const Duration(minutes: 3));
      expect(burst.terminalSeen, isTrue);
      expect(burst.terminalOk, isTrue);
      expect(
        burst.receivedCursors,
        [
          for (var cursor = 1; cursor <= fixture.burstFrames; cursor += 1)
            cursor,
        ],
        reason: 'released capacity resumes bulk in per-stream order',
      );
      expect(burst.mismatchedCursors, isEmpty);
      expect(
        burst.receivedPayloadChars,
        fixture.expectedPayloadChars,
        reason: 'the resumed burst preserves the exact final text',
      );
      expect(fixture.writtenFrames(), [
        for (var cursor = 1; cursor <= fixture.burstFrames; cursor += 1) cursor,
      ]);
      expect(fixture.burstCompleted, isTrue);
      expect(session.pendingDecodeBytes, 0);
      expect(session.decodeBackpressureApplied, isFalse);
      expect(session.usable, isTrue);
      expect(
        session.maxObservedDecodeBacklogBytes,
        lessThanOrEqualTo(backlogBound),
        reason: 'the observed backlog never exceeds the declared bound',
      );
      // ignore: avoid_print
      print(
        'stdio-flow-control native-child backlog-bound: '
        'frames=${fixture.burstFrames} '
        'writtenWhilePaused=${writtenWhilePaused.length} '
        'pendingWhilePaused=$pendingWhilePaused '
        'observedBacklogBytes=${session.maxObservedDecodeBacklogBytes} '
        'bound=$backlogBound',
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

/// Collects one conversation burst while checking every payload exactly.
final class _BurstCollector {
  _BurstCollector(this.fixture);

  final NativeChildFixture fixture;
  final List<int> receivedCursors = [];
  final List<int> mismatchedCursors = [];
  var receivedPayloadChars = 0;
  var terminalSeen = false;
  var terminalOk = false;

  void acceptEvent(Map<String, dynamic> event) {
    final cursor = event['cursor'];
    if (cursor is! int) {
      mismatchedCursors.add(-1);
      return;
    }
    final payload = (event['payload'] as Map?)?['text'];
    final expected = fixture.expectedFrameText(cursor);
    if (payload is! String || payload != expected) {
      mismatchedCursors.add(cursor);
    } else {
      receivedPayloadChars += payload.length;
    }
    receivedCursors.add(cursor);
  }
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
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}
