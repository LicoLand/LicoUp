import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/contracts/generated/conversation_protocol.g.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/protocol.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/request_writer.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/response_codec.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/session.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/stream_observation.dart';

import 'transport_fixture.dart';

/// The control lane must survive bulk that is physically ahead of it on the
/// one shared stdout pipe.
///
/// [ControlBehindBulkFixture] writes a pre-built bulk burst and only then reads
/// and answers the control request, so the acknowledgement bytes are behind
/// every bulk byte of that burst in the same pipe — exactly the position a
/// cancel reply has while a turn is still streaming. A reader that pauses the
/// shared stdout stream to bound its framed backlog cannot reach that reply
/// without first draining the bulk, and this suite measures that instead of
/// accepting a request-write event as proof.
void main() {
  test(
    'a control acknowledgement settles while the bulk written before it stays undelivered',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-stdio-control-behind-bulk-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final fixture = await ControlBehindBulkFixture.create(
        directory: directory,
      );
      final backend = _RecordingBackend();
      final port = StreamObservationPort(
        maxRecordBytes: 1024 * 1024,
        maxRetainedRecords: 64,
        maxRetainedBytes: 32 * 1024 * 1024,
      );
      port.installBackend(backend);
      final context = NativeChildProcessContext(fixture);
      final client = NativeStdioRpcClient(
        processContext: context,
        observation: port,
      );
      addTearDown(client.dispose);

      final burst = _BurstCollector(fixture);
      final terminal = Completer<void>();
      client
          .streamConversation(const {
            'agent': 'synthetic',
            'text': 'synthetic control-behind-bulk probe',
            'conversationId': ControlBehindBulkFixture.conversationId,
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

      // The producer's burst fills the framed backlog and the transport pauses
      // the shared stdout stream while that burst is still in flight. This is
      // the state the defect is about: a control frame written now is behind
      // bulk bytes the transport has not read yet.
      await _waitUntil(
        () =>
            backend.received.any(
              (record) =>
                  record.phase == StreamObservationPhase.acquisition &&
                  record.backlogBytes >= stdioRpcMaxDecodeBacklogBytes,
            ) &&
            !fixture.bulkAheadWritten,
        timeout: const Duration(seconds: 120),
      );

      final cancelClock = Stopwatch()..start();
      final cancel = await client
          .executeStructured('agent.conversation.cancel', const {
            'agent': 'synthetic',
            'sessionId': 'session-1',
            'turnId': ControlBehindBulkFixture.turnHandle,
          })
          .timeout(const Duration(seconds: 90));
      cancelClock.stop();

      expect(cancel, {'ok': true, 'status': 'accepted'});
      final deliveredAtAck = List<int>.of(burst.receivedCursors);
      // The child writes the acknowledgement after the whole pre-control burst
      // reached the pipe, so a reply that settled here really was behind those
      // bulk bytes.
      expect(
        fixture.bulkAheadWritten,
        isTrue,
        reason: 'the acknowledgement is only written after the burst',
      );
      expect(
        deliveredAtAck.length * fixture.frameWireBytes,
        lessThanOrEqualTo(stdioRpcMaxDecodeBacklogBytes ~/ 2),
        reason:
            'the control acknowledgement settled without the reader draining '
            'the bulk written ahead of it',
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
      // The shared stream resumed while the framed backlog was still far above
      // its ordinary resume watermark: control capacity, not draining, released
      // it. A blanket pause can never produce this record.
      final drains = backend.received
          .where((record) => record.phase == StreamObservationPhase.drain)
          .toList(growable: false);
      expect(
        drains.any(
          (record) => record.backlogBytes > stdioRpcResumeDecodeBacklogBytes,
        ),
        isTrue,
        reason:
            'the shared stdout stream resumed above its ordinary resume '
            'watermark because a control reply was behind bulk',
      );
      // Everything the transport retained stayed inside the control-aware
      // bound: the ordinary framed backlog plus the bounded bulk write budget
      // the producer may commit ahead of a control frame.
      final peakBacklog = backend.received.fold<int>(
        0,
        (peak, record) =>
            record.backlogBytes > peak ? record.backlogBytes : peak,
      );
      expect(
        peakBacklog,
        lessThanOrEqualTo(stdioRpcControlWindowBacklogBytes),
        reason: 'the control window keeps the framed backlog bounded',
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
          for (var cursor = 1; cursor <= fixture.totalFrames; cursor += 1)
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
      expect(fixture.controlAnswered, isTrue);
      expect(fixture.releaseCompleted, isTrue);
      expect(context.startCount, 1);
      // ignore: avoid_print
      print(
        'stdio-flow-control control-behind-bulk: '
        'cancelAckMs=${cancelClock.elapsedMilliseconds} '
        'deliveredAtAck=${deliveredAtAck.length}/${fixture.bulkAheadFrames} '
        'deliveredAtAckBytes=${deliveredAtAck.length * fixture.frameWireBytes} '
        'peakBacklogBytes=$peakBacklog '
        'resumeWatermark=$stdioRpcResumeDecodeBacklogBytes '
        'burstBytes=${fixture.bulkAheadWireBytes}',
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'the transport reads past the ordinary watermark for control and stays bounded',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-stdio-control-window-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final fixture = await ControlBehindBulkFixture.create(
        directory: directory,
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
      const bulkRequestId = 'request-behind-bulk';
      const controlRequestId = 'request-control-lane';
      const workflowId = 'workflow-behind-bulk';

      final burst = _BurstCollector(fixture);
      final terminal = Completer<void>();
      session
          .expectConversationFrames(
            requestId: bulkRequestId,
            workflowId: workflowId,
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
          id: bulkRequestId,
          workflowId: workflowId,
          method: ConversationProtocolMethod.agentConversationSend,
          params: const {
            'agent': 'synthetic',
            'text': 'synthetic control-behind-bulk probe',
            'conversationId': ControlBehindBulkFixture.conversationId,
          },
        ).encode(),
      );

      // The burst outruns the decode lane, so the shared pipe is paused at the
      // ordinary watermark with bulk still unread ahead of any control reply.
      await _waitUntil(
        () => session.decodeBackpressureApplied,
        timeout: const Duration(seconds: 180),
      );
      final backlogAtPause = session.pendingDecodeBytes;
      expect(
        backlogAtPause,
        greaterThanOrEqualTo(stdioRpcMaxDecodeBacklogBytes),
        reason: 'the pause is applied at the declared watermark',
      );

      final reply = session.expectFrame(
        requestId: controlRequestId,
        control: true,
      );
      expect(session.controlWindowActive, isTrue);
      expect(
        session.decodeBackpressureApplied,
        isFalse,
        reason:
            'a control request releases the shared pipe instead of waiting for '
            'the backlog to drain below the ordinary resume watermark',
      );
      await writeStdioRpcFrame(
        session,
        ConversationCommand(
          id: controlRequestId,
          workflowId: workflowId,
          method: ConversationProtocolMethod.agentConversationCancel,
          params: const {
            'agent': 'synthetic',
            'sessionId': 'session-1',
            'turnId': ControlBehindBulkFixture.turnHandle,
          },
        ).encode(),
      );
      final frame = await reply.timeout(const Duration(seconds: 90));
      expect(frame.envelope?['id'], controlRequestId);
      expect(frame.envelope?['ok'], isTrue);
      final deliveredAtAck = burst.receivedCursors.length;
      expect(
        fixture.bulkAheadWritten,
        isTrue,
        reason: 'the acknowledgement is only written after the burst',
      );
      expect(
        session.controlWindowAdmittedBytes,
        greaterThan(0),
        reason:
            'the transport admitted bulk past the ordinary watermark because a '
            'control reply was behind it',
      );
      expect(
        session.maxObservedDecodeBacklogBytes,
        lessThanOrEqualTo(
          stdioRpcControlWindowBacklogBytes + fixture.frameWireBytes,
        ),
        reason: 'the framed backlog stays inside the declared control window',
      );
      expect(
        deliveredAtAck,
        lessThan(fixture.bulkAheadFrames),
        reason: 'the acknowledgement settled ahead of the remaining bulk',
      );
      expect(session.usable, isTrue);

      await terminal.future.timeout(const Duration(minutes: 3));
      expect(burst.terminalSeen, isTrue);
      expect(burst.terminalOk, isTrue);
      expect(burst.receivedCursors, [
        for (var cursor = 1; cursor <= fixture.totalFrames; cursor += 1) cursor,
      ]);
      expect(burst.mismatchedCursors, isEmpty);
      expect(burst.receivedPayloadChars, fixture.expectedPayloadChars);
      expect(fixture.releaseCompleted, isTrue);
      expect(session.pendingDecodeBytes, 0);
      expect(session.decodeBackpressureApplied, isFalse);
      expect(session.controlWindowActive, isFalse);
      // ignore: avoid_print
      print(
        'stdio-flow-control control-window: '
        'backlogAtPause=$backlogAtPause '
        'windowAdmittedBytes=${session.controlWindowAdmittedBytes} '
        'windowCount=${session.controlWindowCount} '
        'deliveredAtAck=$deliveredAtAck/${fixture.bulkAheadFrames} '
        'peakBacklogBytes=${session.maxObservedDecodeBacklogBytes} '
        'windowBound=$stdioRpcControlWindowBacklogBytes '
        'observedMaxFrames=${fixture.totalFrames}',
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

/// Collects one conversation burst while checking every payload exactly.
final class _BurstCollector {
  _BurstCollector(this.fixture);

  final ControlBehindBulkFixture fixture;
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

final class _RecordingBackend implements StreamObservationBackend {
  final List<StreamObservationRecord> received = [];

  @override
  void acceptStreamObservation(StreamObservationRecord record) =>
      received.add(record);
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
