import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/protocol.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/response_codec.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/session.dart';

import 'transport_harness.dart';

/// A15 component harness: the transport decodes bulk frames on a bounded lane
/// and lets a single-shot control reply (cancel/steer/terminal settlement)
/// leave the bulk backlog instead of waiting behind it.
void main() {
  test(
    'control dispatch leaves a near-max-size bulk decode, ordinary replies keep wire order',
    () async {
      final process = SyntheticNativeProcess((request) {});
      final session = StdioRpcSession(process);
      addTearDown(() async {
        await session.close(kill: false);
        await process.exitCode.timeout(
          const Duration(seconds: 1),
          onTimeout: () => -1,
        );
      });
      final bulk = session.expectFrame(requestId: 'bulk');
      final control = session.expectFrame(requestId: 'control', control: true);
      final ordered = session.expectFrame(requestId: 'ordered');

      // Just under stdioRpcMaxFrameBytes: the largest frame the transport
      // accepts, so this is the real bulk-decode cost, not a small stand-in.
      final filler = _filler(stdioRpcMaxFrameBytes - 1024 * 1024);
      final bulkFrame = utf8.encode(
        '${jsonEncode({
          'id': 'bulk',
          'result': {'text': filler},
        })}\n',
      );
      expect(bulkFrame.length, lessThan(stdioRpcMaxFrameBytes));

      final bulkSettled = Completer<int>();
      final bulkClock = Stopwatch()..start();
      unawaited(
        bulk.then((frame) {
          bulkClock.stop();
          bulkSettled.complete(
            ((frame.envelope?['result'] as Map?)?['text'] as String?)?.length ??
                -1,
          );
        }),
      );
      process.sendFrameBytes(bulkFrame);
      process.sendFrame(
        jsonEncode({
          'id': 'ordered',
          'result': {'kind': 'ordered'},
        }),
      );
      // The control frame is behind the bulk frame on the wire; only a real
      // control lane can settle it first.
      final controlClock = Stopwatch()..start();
      var orderedSettled = false;
      unawaited(ordered.then((_) => orderedSettled = true));
      process.sendFrame(
        jsonEncode({
          'id': 'control',
          'result': {'kind': 'control'},
        }),
      );

      final controlReply = await control.timeout(const Duration(seconds: 10));
      controlClock.stop();
      expect(controlReply.envelope?['result'], {'kind': 'control'});
      expect(
        bulkSettled.isCompleted,
        isFalse,
        reason: 'the near-max-size bulk frame is still decoding off-isolate',
      );
      expect(
        session.pendingDecodeBytes,
        greaterThan(0),
        reason: 'the bulk frame is still inside the bounded decode backlog',
      );
      expect(
        orderedSettled,
        isFalse,
        reason: 'ordinary replies never overtake an earlier frame',
      );
      expect(session.usable, isTrue);

      final bulkLength = await bulkSettled.future.timeout(
        const Duration(seconds: 30),
      );
      expect(bulkLength, filler.length);
      final orderedReply = await ordered.timeout(const Duration(seconds: 10));
      expect(orderedReply.envelope?['result'], {'kind': 'ordered'});
      // ignore: avoid_print
      print(
        'V7-F4 decode-lane: control=${controlClock.elapsedMilliseconds}ms '
        'bulk=${bulkClock.elapsedMilliseconds}ms '
        'frameBytes=${bulkFrame.length} '
        'observedBacklogBytes=${session.maxObservedDecodeBacklogBytes}',
      );
      expect(
        controlClock.elapsedMilliseconds,
        lessThan(bulkClock.elapsedMilliseconds),
        reason: 'control latency must not track the bulk decode',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'a bulk flood stays inside the declared decode bound and keeps wire order',
    () async {
      const frameCount = 24;
      const frameFillerBytes = 1024 * 1024;
      final process = SyntheticNativeProcess((request) {});
      final session = StdioRpcSession(process);
      addTearDown(() async {
        await session.close(kill: false);
        await process.exitCode.timeout(
          const Duration(seconds: 1),
          onTimeout: () => -1,
        );
      });
      final replies = <Future<StdioRpcFrame>>[];
      final filler = _filler(frameFillerBytes);
      for (var index = 0; index < frameCount; index += 1) {
        replies.add(session.expectFrame(requestId: 'bulk-$index'));
      }
      // The whole flood is handed to the transport before the event loop can
      // dispatch any of it, so the backlog must hit its watermark and pause
      // stdout instead of growing with the flood.
      for (var index = 0; index < frameCount; index += 1) {
        process.sendFrameBytes(
          utf8.encode(
            '${jsonEncode({
              'id': 'bulk-$index',
              'result': {'text': '$index:$filler'},
            })}\n',
          ),
        );
      }
      await Future<void>.delayed(Duration.zero);
      final backpressureApplied = session.decodeBackpressureApplied;
      // The watermark plus the chunk that reached it is the transport's
      // declared memory bound.
      final backlogBound =
          stdioRpcMaxDecodeBacklogBytes + frameFillerBytes + 4096;
      expect(
        session.pendingDecodeBytes,
        lessThanOrEqualTo(backlogBound),
        reason: 'framed-but-undispatched bytes are bounded by the watermark',
      );
      final settled = await Future.wait(
        replies,
      ).timeout(const Duration(seconds: 120));
      expect(
        settled.map((frame) => frame.envelope?['id']),
        [for (var index = 0; index < frameCount; index += 1) 'bulk-$index'],
        reason: 'dispatched replies stay in wire order',
      );
      expect(session.usable, isTrue);
      expect(backpressureApplied, isTrue);
      expect(
        session.maxObservedDecodeBacklogBytes,
        lessThanOrEqualTo(backlogBound),
        reason: 'the observed backlog never exceeds the declared bound',
      );
      // ignore: avoid_print
      print(
        'V7-F4 decode-bound: frames=$frameCount '
        'observedBacklogBytes=${session.maxObservedDecodeBacklogBytes} '
        'bound=$stdioRpcMaxDecodeBacklogBytes '
        'paused=$backpressureApplied',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'one conversation stream keeps its frame order across large events',
    () async {
      const eventCount = 6;
      final process = SyntheticNativeProcess((request) {});
      final session = StdioRpcSession(process);
      addTearDown(() async {
        await session.close(kill: false);
        await process.exitCode.timeout(
          const Duration(seconds: 1),
          onTimeout: () => -1,
        );
      });
      final frames = session.expectConversationFrames(
        requestId: 'turn',
        workflowId: 'workflow',
      );
      final cursorOrder = <int>[];
      final settled = Completer<bool>();
      frames.listen(
        (frame) {
          if (frame is StdioRpcConversationEvent) {
            cursorOrder.add(frame.event['cursor'] as int);
          }
          if (frame is StdioRpcConversationTerminal) {
            settled.complete(true);
          }
        },
        onError: (Object error) => settled.complete(false),
        onDone: () {
          if (!settled.isCompleted) settled.complete(false);
        },
      );
      final bulkFiller = _filler(2 * 1024 * 1024);
      for (var index = 1; index <= eventCount; index += 1) {
        process.sendFrame(
          stdioRpcConversationEvent(
            requestId: 'turn',
            workflowId: 'workflow',
            sequence: index,
            cursor: index,
            turnHandle: 'turn-1',
            conversationId: 'conversation-1',
            filler: index.isEven ? '$index:$bulkFiller' : 'small-$index',
          ),
        );
      }
      process.sendFrame(
        stdioRpcConversationTerminal(
          requestId: 'turn',
          workflowId: 'workflow',
          sequence: eventCount + 1,
        ),
      );
      expect(await settled.future.timeout(const Duration(seconds: 60)), isTrue);
      expect(cursorOrder, [
        for (var index = 1; index <= eventCount; index += 1) index,
      ]);
      expect(session.usable, isTrue);
      // ignore: avoid_print
      print(
        'V7-F4 stream-order: events=${cursorOrder.length} '
        'observedBacklogBytes=${session.maxObservedDecodeBacklogBytes}',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'teardown during a bulk decode settles pending frames',
    () async {
      final process = SyntheticNativeProcess((request) {});
      final session = StdioRpcSession(process);
      final bulk = session.expectFrame(requestId: 'bulk');
      final filler = _filler(8 * 1024 * 1024);
      process.sendFrameBytes(
        utf8.encode(
          '${jsonEncode({
            'id': 'bulk',
            'result': {'text': filler},
          })}\n',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(session.pendingDecodeBytes, greaterThan(0));
      final close = session.close(kill: false);
      final frame = await bulk.timeout(const Duration(seconds: 10));
      expect(frame.envelope, isNull, reason: 'teardown fails the expectation');
      expect(session.usable, isFalse);
      await close.timeout(const Duration(seconds: 10));
      expect(session.maxObservedDecodeBacklogBytes, greaterThan(0));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

String _filler(int length) {
  const unit = 'licoup-v7-f4-transport-payload-';
  final buffer = StringBuffer();
  while (buffer.length < length) {
    buffer.write(unit);
  }
  return buffer.toString().substring(0, length);
}
