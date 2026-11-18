import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/protocol.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/session.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/stream_observation.dart';

import 'transport_fixture.dart';

/// The transport reports its bounded phases to one optional observation port.
/// The port fails closed without an installed backend, refuses oversized or
/// identifying records instead of truncating them, keeps only a bounded window
/// and drops under pressure, while the transport itself never depends on it.
void main() {
  test('an uninstalled port refuses every phase and holds no record', () {
    final port = StreamObservationPort();

    expect(port.isInstalled, isFalse);
    for (final phase in StreamObservationPhase.values) {
      final admission = port.observe(
        phase: phase,
        sizeBytes: 1024,
        correlationId: 'request-1',
      );
      expect(
        admission,
        isA<StreamObservationRefused>(),
        reason: 'phase $phase must be refused without a backend',
      );
      expect(
        (admission as StreamObservationRefused).reason,
        StreamObservationRefusal.noBackend,
      );
    }
    expect(port.retainedRecords, isEmpty);
    expect(port.retainedCount, 0);
    expect(port.retainedBytes, 0);
    expect(port.evictedCount, 0);
  });

  test('oversized and identifying records are refused, never truncated', () {
    final backend = _RecordingBackend();
    final port = StreamObservationPort(
      maxRecordBytes: 4096,
      maxCorrelationChars: 16,
      maxRetainedRecords: 8,
      maxRetainedBytes: 32 * 1024,
    );
    port.installBackend(backend);

    expect(
      _refusal(
        port.observe(
          phase: StreamObservationPhase.decode,
          sizeBytes: 4097,
          correlationId: 'request-1',
        ),
      ),
      StreamObservationRefusal.oversizedRecord,
    );
    expect(
      _refusal(
        port.observe(
          phase: StreamObservationPhase.dispatch,
          sizeBytes: 64,
          correlationId: 'request-1',
          privacy: StreamObservationPrivacy.identifying,
        ),
      ),
      StreamObservationRefusal.identifyingRecord,
    );
    expect(
      _refusal(
        port.observe(
          phase: StreamObservationPhase.install,
          sizeBytes: 64,
          correlationId: 'x' * 17,
        ),
      ),
      StreamObservationRefusal.oversizedCorrelation,
    );
    expect(
      backend.received,
      isEmpty,
      reason: 'a refused record never reaches the installed backend',
    );
    expect(port.retainedCount, 0);
    expect(port.evictedCount, 0);

    // A record exactly at each bound is admitted, not trimmed to fit.
    final admitted = port.observe(
      phase: StreamObservationPhase.decode,
      sizeBytes: 4096,
      correlationId: 'x' * 16,
    );
    expect(admitted, isA<StreamObservationAdmitted>());
    expect(backend.received.single.sizeBytes, 4096);
    expect(backend.received.single.correlationId.length, 16);
  });

  test('the bounded window evicts its oldest records under pressure', () {
    final backend = _RecordingBackend();
    final port = StreamObservationPort(
      maxRecordBytes: 64,
      maxCorrelationChars: 16,
      maxRetainedRecords: 3,
      maxRetainedBytes: 100,
    );
    port.installBackend(backend);

    for (var index = 0; index < 6; index += 1) {
      final admission =
          port.observe(
                phase: StreamObservationPhase.acquisition,
                sizeBytes: 40,
                correlationId: 'request-$index',
              )
              as StreamObservationAdmitted;
      expect(admission.retainedCount, lessThanOrEqualTo(3));
      expect(admission.retainedBytes, lessThanOrEqualTo(100));
    }

    expect(port.retainedCount, lessThanOrEqualTo(3));
    expect(port.retainedBytes, lessThanOrEqualTo(100));
    expect(
      port.evictedCount,
      4,
      reason: 'each pressured admission dropped its oldest retained record',
    );
    expect(port.retainedRecords.map((record) => record.correlationId), [
      'request-4',
      'request-5',
    ]);
    expect(
      backend.received.map((record) => record.correlationId),
      [
        'request-0',
        'request-1',
        'request-2',
        'request-3',
        'request-4',
        'request-5',
      ],
      reason: 'the backend receives every admitted record in order',
    );
    expect(
      _refusal(
        port.observe(
          phase: StreamObservationPhase.decode,
          sizeBytes: 65,
          correlationId: 'request-6',
        ),
      ),
      StreamObservationRefusal.oversizedRecord,
    );
    expect(port.retainedCount, lessThanOrEqualTo(3));
  });

  test(
    'a transport without an installed backend observes nothing and works',
    () async {
      final port = StreamObservationPort();
      final process = SyntheticNativeProcess((request) {});
      final session = StdioRpcSession(process, observation: port);
      addTearDown(() => _closeSession(session, process));

      final reply = session.expectFrame(
        requestId: 'unobserved',
        control: true,
        sizeBytes: 64,
      );
      process.sendFrame(
        jsonEncode({
          'id': 'unobserved',
          'result': {'ok': true},
        }),
      );
      final frame = await reply.timeout(const Duration(seconds: 5));

      expect(frame.envelope?['result'], {'ok': true});
      expect(port.isInstalled, isFalse);
      expect(port.retainedRecords, isEmpty);
      expect(port.retainedCount, 0);
      expect(port.retainedBytes, 0);
      expect(port.evictedCount, 0);
    },
  );

  test('a session without any observation port still settles frames', () async {
    final process = SyntheticNativeProcess((request) {});
    final session = StdioRpcSession(process);
    addTearDown(() => _closeSession(session, process));

    final reply = session.expectFrame(requestId: 'portless');
    process.sendFrame(
      jsonEncode({
        'id': 'portless',
        'result': {'ok': true},
      }),
    );

    expect(
      (await reply.timeout(const Duration(seconds: 5))).envelope?['result'],
      {'ok': true},
    );
  });

  test(
    'installed observation reports the phases and the control lane facts',
    () async {
      final backend = _RecordingBackend();
      final port = StreamObservationPort();
      port.installBackend(backend);
      final process = SyntheticNativeProcess((request) {});
      final session = StdioRpcSession(process, observation: port);
      addTearDown(() => _closeSession(session, process));

      final control = session.expectFrame(
        requestId: 'cancel-1',
        control: true,
        sizeBytes: 128,
      );
      final ordered = session.expectFrame(requestId: 'plain-1', sizeBytes: 64);
      final orderedBytes = utf8.encode(
        '${jsonEncode({
          'id': 'plain-1',
          'result': {'ok': true},
        })}\n',
      );
      final controlBytes = utf8.encode(
        '${jsonEncode({
          'id': 'cancel-1',
          'result': {'ok': true, 'status': 'accepted'},
        })}\n',
      );
      // One stdout chunk carries both replies, so the framed backlog the
      // watermarks bound is observable before either frame dispatches.
      process.sendFrameBytes([...orderedBytes, ...controlBytes]);

      await Future.wait([
        control,
        ordered,
      ]).timeout(const Duration(seconds: 10));

      final records = backend.received;
      expect(
        records.map((record) => record.phase).toSet(),
        containsAll(StreamObservationPhase.values),
        reason: 'acquisition, decode, dispatch, install and drain are reported',
      );
      final acquisition = records.singleWhere(
        (record) => record.phase == StreamObservationPhase.acquisition,
      );
      expect(acquisition.sizeBytes, orderedBytes.length + controlBytes.length);
      expect(
        acquisition.backlogBytes,
        orderedBytes.length + controlBytes.length - 2,
        reason: 'the framed backlog excludes both line terminators',
      );

      // The control lane's attempt is its installed expectation; its
      // settlement is the dispatched reply.
      final attempt = records.singleWhere(
        (record) =>
            record.phase == StreamObservationPhase.install &&
            record.lane == StreamObservationLane.control,
      );
      expect(attempt.correlationId, 'cancel-1');
      expect(attempt.sizeBytes, 128);
      final settlement = records.singleWhere(
        (record) =>
            record.phase == StreamObservationPhase.dispatch &&
            record.lane == StreamObservationLane.control,
      );
      expect(settlement.correlationId, 'cancel-1');
      final orderedDispatch = records.singleWhere(
        (record) =>
            record.phase == StreamObservationPhase.dispatch &&
            record.lane == StreamObservationLane.ordered,
      );
      expect(orderedDispatch.correlationId, 'plain-1');
      final decodes = records
          .where((record) => record.phase == StreamObservationPhase.decode)
          .map((record) => record.correlationId);
      expect(decodes, containsAll(['cancel-1', 'plain-1']));

      final drain = records.lastWhere(
        (record) => record.phase == StreamObservationPhase.drain,
      );
      expect(drain.backlogBytes, 0);
      expect(port.retainedCount, records.length);
    },
  );

  test(
    'admitted records survive the synthetic session exit and refusals do not',
    () async {
      final backend = _RecordingBackend();
      final port = StreamObservationPort();
      port.installBackend(backend);
      final process = SyntheticNativeProcess((request) {});
      final session = StdioRpcSession(process, observation: port);

      final reply = session.expectFrame(requestId: 'exit-1', sizeBytes: 32);
      process.sendFrame(
        jsonEncode({
          'id': 'exit-1',
          'result': {'ok': true},
        }),
      );
      await reply.timeout(const Duration(seconds: 5));
      final retainedBeforeExit = port.retainedCount;
      expect(retainedBeforeExit, greaterThan(0));

      await session.close(kill: true);
      await process.exitCode.timeout(const Duration(seconds: 1));

      expect(process.killed, isTrue);
      expect(port.retainedCount, retainedBeforeExit);
      expect(port.retainedRecords, isNotEmpty);
      expect(backend.received, isNotEmpty);
      expect(
        _refusal(
          port.observe(
            phase: StreamObservationPhase.decode,
            sizeBytes: port.maxRecordBytes + 1,
            correlationId: 'after-exit',
          ),
        ),
        StreamObservationRefusal.oversizedRecord,
      );
      expect(port.retainedCount, retainedBeforeExit);
    },
  );

  test('a throwing backend cannot fail the transport it observes', () async {
    final port = StreamObservationPort();
    port.installBackend(const _ThrowingBackend());
    final process = SyntheticNativeProcess((request) {});
    final session = StdioRpcSession(process, observation: port);
    addTearDown(() => _closeSession(session, process));

    final reply = session.expectFrame(requestId: 'throwing');
    process.sendFrame(
      jsonEncode({
        'id': 'throwing',
        'result': {'ok': true},
      }),
    );

    expect(
      (await reply.timeout(const Duration(seconds: 5))).envelope?['result'],
      {'ok': true},
    );
    expect(port.retainedCount, greaterThan(0));
  });

  test(
    'client sessions observe the control lane through the installed backend',
    () async {
      late SyntheticNativeRequest sendRequest;
      final context = SyntheticProcessContext((request) {
        switch (request.method) {
          case 'agent.conversation.send':
            sendRequest = request;
            request.process.sendFrame(
              stdioRpcConversationEvent(
                requestId: request.id,
                workflowId: request.workflowId,
                sequence: 1,
                cursor: 1,
                turnHandle: 'turn-1',
                conversationId: 'conversation-1',
              ),
            );
          case 'agent.conversation.cancel':
            request.reply({'ok': true, 'status': 'accepted'});
            request.process.sendFrame(
              stdioRpcConversationTerminal(
                requestId: sendRequest.id,
                workflowId: sendRequest.workflowId,
                sequence: 2,
              ),
            );
          default:
            request.reply(const {});
        }
      });
      final backend = _RecordingBackend();
      final port = StreamObservationPort();
      port.installBackend(backend);
      final client = NativeStdioRpcClient(
        processContext: context,
        observation: port,
      );
      addTearDown(client.dispose);

      final streamDone = Completer<void>();
      client
          .streamConversation(const {'agent': 'synthetic', 'text': 'probe'})
          .listen(
            (_) {},
            onDone: streamDone.complete,
            onError: (Object _) => streamDone.complete(),
          );
      await _waitUntil(
        () => backend.received.any(
          (record) =>
              record.phase == StreamObservationPhase.install &&
              record.lane == StreamObservationLane.ordered,
        ),
      );

      final cancel = await client
          .executeStructured('agent.conversation.cancel', const {
            'agent': 'synthetic',
            'sessionId': 'session-1',
            'turnId': 'turn-1',
          })
          .timeout(const Duration(seconds: 30));

      expect(cancel['ok'], isTrue);
      expect(
        backend.received.any(
          (record) =>
              record.phase == StreamObservationPhase.install &&
              record.lane == StreamObservationLane.control,
        ),
        isTrue,
        reason: 'the control attempt is observable through the client',
      );
      expect(
        backend.received.any(
          (record) =>
              record.phase == StreamObservationPhase.dispatch &&
              record.lane == StreamObservationLane.control,
        ),
        isTrue,
        reason: 'the control settlement is observable through the client',
      );
      await streamDone.future.timeout(const Duration(seconds: 30));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'a paused decode backlog releases at the resume watermark and is observed',
    () async {
      final backend = _RecordingBackend();
      final port = StreamObservationPort(
        maxRecordBytes: 32 * 1024 * 1024,
        maxRetainedRecords: 64,
        maxRetainedBytes: 32 * 1024 * 1024,
      );
      port.installBackend(backend);
      final process = SyntheticNativeProcess((request) {});
      final session = StdioRpcSession(process, observation: port);
      addTearDown(() => _closeSession(session, process));

      final first = session.expectFrame(requestId: 'bulk-1', sizeBytes: 16);
      final second = session.expectFrame(requestId: 'bulk-2', sizeBytes: 16);
      // Two frames above the bulk decode threshold exceed the framed decode
      // backlog bound, so stdout pauses before either frame is dispatched.
      final filler = 'x' * (9 * 1024 * 1024);
      final chunk = utf8.encode(
        '${jsonEncode({
          'id': 'bulk-1',
          'result': {'text': filler},
        })}\n'
        '${jsonEncode({
          'id': 'bulk-2',
          'result': {'text': filler},
        })}\n',
      );
      expect(chunk.length, greaterThan(stdioRpcMaxDecodeBacklogBytes));
      process.sendFrameBytes(chunk);

      await Future.wait([first, second]).timeout(const Duration(seconds: 120));

      expect(
        session.maxObservedDecodeBacklogBytes,
        greaterThanOrEqualTo(stdioRpcMaxDecodeBacklogBytes),
      );
      expect(
        backend.received
            .singleWhere(
              (record) => record.phase == StreamObservationPhase.acquisition,
            )
            .backlogBytes,
        greaterThanOrEqualTo(stdioRpcMaxDecodeBacklogBytes),
      );
      final drains = backend.received
          .where((record) => record.phase == StreamObservationPhase.drain)
          .toList();
      expect(drains, isNotEmpty);
      expect(
        drains.last.backlogBytes,
        lessThanOrEqualTo(stdioRpcResumeDecodeBacklogBytes),
      );
      expect(session.decodeBackpressureApplied, isFalse);
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

final class _RecordingBackend implements StreamObservationBackend {
  final List<StreamObservationRecord> received = [];

  @override
  void acceptStreamObservation(StreamObservationRecord record) =>
      received.add(record);
}

final class _ThrowingBackend implements StreamObservationBackend {
  const _ThrowingBackend();

  @override
  void acceptStreamObservation(StreamObservationRecord record) =>
      throw StateError('observation_backend_failed');
}

StreamObservationRefusal _refusal(StreamObservationAdmission admission) {
  expect(admission, isA<StreamObservationRefused>());
  return (admission as StreamObservationRefused).reason;
}

Future<void> _closeSession(
  StdioRpcSession session,
  SyntheticNativeProcess process,
) async {
  await session.close(kill: false);
  await process.exitCode.timeout(
    const Duration(seconds: 1),
    onTimeout: () => -1,
  );
}

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('condition was not met before $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
