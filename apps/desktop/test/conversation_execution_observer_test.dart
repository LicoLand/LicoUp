import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_execution_observer.dart';
import 'package:licoup/src/backend/features/agents/services/agent_conversation_service.dart';
import 'package:licoup/src/contracts/conversation_execution.dart';
import 'package:licoup/src/contracts/conversation_execution_port.dart';
import 'package:licoup/src/contracts/conversation_native_port.dart';
import 'package:licoup/src/contracts/generated/conversation_protocol.g.dart';
import 'package:licoup/src/platform/native_client/native_conversation_port.dart';
import 'package:licoup/src/presentation/conversation/conversation_execution_projection.dart';
import 'package:licoup/src/projections/conversation/conversation_execution_projection_producer.dart';

import 'support/fake_conversation_transport.dart';

const _reference = ConversationExecutionReference(
  conversationId: 'conversation-fixture',
  membershipId: 'membership-fixture',
  turnHandle: 'dispatch-fixture',
);

ConversationExecutionReady _ready({
  String status = 'running',
  bool available = true,
  bool terminal = false,
  int cursor = 0,
}) => ConversationExecutionReady(
  reference: _reference,
  cursor: cursor,
  status: status,
  observationAvailable: available,
  terminalPayloadAvailable: terminal,
);

ConversationExecutionRecordEvent _record(int cursor, {String? rawText}) =>
    ConversationExecutionRecordEvent(
      ConversationExecutionRecord(
        id: 'dispatch-fixture:$cursor',
        rawText: rawText ?? 'record $cursor',
        kind: 'runtime',
        timestamp: '1234567890000',
        cursor: cursor,
      ),
    );

Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  test(
    'execution surfaces keep exact references and independent immutable prefixes',
    () async {
      final source = _Source();
      final projection = ConversationExecutionProjectionProducer(
        NativeConversationExecutionReader(source),
      );
      addTearDown(projection.close);
      final first = ConversationExecutionViewId();
      final second = ConversationExecutionViewId();
      const other = ConversationExecutionReference(
        conversationId: 'conversation-fixture',
        membershipId: 'another-membership',
        turnHandle: 'another-dispatch',
      );
      projection.open(first, _reference);
      projection.open(second, other);
      projection.open(first, other);
      expect(projection.current.views[first]!.loading, isTrue);
      await _flush();
      expect(source.references, [_reference, other]);
      final raw = _record(1, rawText: '{ "unknown": ["原文", 2] }\r\n');
      source.streams[0].add(raw);
      source.streams[1].add(_record(1, rawText: 'other execution'));
      await _flush();
      final before = projection.current;
      expect(before.views[first]!.records.single, same(raw.record));
      expect(() => before.views.clear(), throwsUnsupportedError);
      source.streams[0].add(_record(3));
      await _flush();
      expect(before.views[first]!.records, hasLength(1));
      expect(projection.current.views[first]!.records, hasLength(2));
      expect(
        projection.current.views[first]!.records.first,
        same(before.views[first]!.records.first),
      );
      expect(projection.current.views[second], same(before.views[second]));
      projection.dismiss(first);
      await _flush();
      expect(source.cancelled, 1);
      expect(projection.current.views.containsKey(first), isFalse);
      source.streams[1].add(_record(4, rawText: 'still live'));
      await _flush();
      expect(
        projection.current.views[second]!.records.last.rawText,
        'still live',
      );
      expect(source.executionRunning, isTrue);
      await projection.close();
      await _flush();
      expect(source.cancelled, 2);
    },
  );

  test(
    'closing the projection owner detaches all open execution surfaces',
    () async {
      final source = _Source();
      final projection = ConversationExecutionProjectionProducer(
        NativeConversationExecutionReader(source),
      );
      projection.open(ConversationExecutionViewId(), _reference);
      projection.open(ConversationExecutionViewId(), _reference);
      await _flush();
      expect(source.references, [_reference, _reference]);
      await projection.close();
      await _flush();
      expect(source.cancelled, 2);
      expect(source.executionRunning, isTrue);
      expect(projection.current.views, isEmpty);
      projection.open(ConversationExecutionViewId(), _reference);
      await projection.close();
      await _flush();
      expect(source.references, hasLength(2));
      expect(source.cancelled, 2);
    },
  );

  test(
    'all historical records precede live records; ready ends loading and snapshots remain stable',
    () async {
      final source = _Source();
      final observation = NativeConversationExecutionReader(
        source,
      ).observe(_reference);
      addTearDown(observation.dispose);
      expect(observation.snapshot.loading, isTrue);
      await _flush();
      for (var cursor = 1; cursor <= 35; cursor++) {
        source.streams.single.add(_record(cursor));
      }
      await _flush();
      final historical = observation.snapshot;
      expect(historical.records, hasLength(35));
      expect(historical.loading, isTrue);
      source.streams.single.add(_ready(cursor: 35));
      await _flush();
      expect(observation.snapshot.loading, isFalse);
      expect(observation.snapshot.observationAvailable, isTrue);
      source.streams.single.add(_record(36));
      source.streams.single.add(
        _ready(
          status: 'completed',
          available: false,
          terminal: true,
          cursor: 36,
        ),
      );
      await source.streams.single.close();
      await _flush();
      expect(historical.records, hasLength(35));
      expect(observation.snapshot.records, hasLength(36));
      expect(observation.snapshot.status, 'completed');
      expect(observation.snapshot.terminalPayloadAvailable, isTrue);
      expect(observation.snapshot.loading, isFalse);
    },
  );

  test(
    'reconnect resumes exact execution cursor, deduplicates replay and disposal only detaches',
    () async {
      final source = _Source();
      final observation = NativeConversationExecutionReader(
        source,
      ).observe(_reference);
      await _flush();
      source.streams[0].add(_record(1));
      source.streams[0].add(_ready(cursor: 1));
      await _flush();
      observation.reconnect();
      await _flush();
      expect(source.requests, [0, 1]);
      expect(source.references, [_reference, _reference]);
      expect(source.cancelled, 1);
      source.streams[1].add(_record(1));
      source.streams[1].add(_record(2));
      source.streams[1].add(_ready(cursor: 2));
      await _flush();
      expect(observation.snapshot.records.map((record) => record.cursor), [
        1,
        2,
      ]);
      observation.dispose();
      await _flush();
      expect(source.cancelled, 2);
      expect(source.executionRunning, isTrue);
    },
  );

  test(
    'observer absence is not a fabricated execution terminal and history errors end loading',
    () async {
      final source = _Source();
      final observation = NativeConversationExecutionReader(
        source,
      ).observe(_reference);
      addTearDown(observation.dispose);
      await _flush();
      source.streams[0].add(_ready(available: false));
      await source.streams[0].close();
      await _flush();
      expect(observation.snapshot.status, 'running');
      expect(observation.snapshot.observationAvailable, isFalse);
      expect(observation.snapshot.loading, isFalse);
      observation.reconnect();
      await _flush();
      source.streams[1].addError(
        const NativeConversationException('execution_history_unavailable'),
      );
      await _flush();
      expect(observation.snapshot.loading, isFalse);
      expect(observation.snapshot.errorCode, 'execution_history_unavailable');
    },
  );

  test(
    'dedicated native execution stream preserves unknown fields, whitespace, arrays and fragmented large raw text',
    () async {
      final raw =
          '  {\n"unknown": [1, {"nested": ["x", null, true]}],\n"text": "${List.filled(600000, 'x').join()}"\n}\r\n';
      final split = raw.length ~/ 2;
      final peer = FakeConversationTransport(
        events: (method, params) async* {
          expect(method, ConversationProtocolMethod.agentConversationExecution);
          expect(params['membershipId'], _reference.membershipId);
          expect(params['afterCursor'], 8);
          for (var part = 0; part < 2; part++) {
            yield {
              'event': 'agent.execution.record',
              ..._reference.toJson(),
              'partIndex': part,
              'partCount': 2,
              'record': {
                'id': 'dispatch-fixture:9',
                'cursor': 9,
                'kind': 'runtime',
                'timestamp': 1234567890000,
                'rawText': part == 0
                    ? raw.substring(0, split)
                    : raw.substring(split),
              },
            };
          }
          yield {
            'event': 'agent.execution.ready',
            ..._reference.toJson(),
            'cursor': 9,
            'status': 'completed',
            'observationAvailable': false,
            'terminalPayloadAvailable': true,
          };
          yield {
            'ok': true,
            ..._reference.toJson(),
            'cursor': 9,
            'status': 'completed',
            'observationAvailable': false,
            'terminalPayloadAvailable': true,
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
          .watchExecution(_reference, afterCursor: 8)
          .toList();
      final record = events
          .whereType<ConversationExecutionRecordEvent>()
          .single
          .record;
      expect(record.rawText, raw);
      expect(record.cursor, 9);
      expect(events.whereType<ConversationExecutionReady>(), hasLength(2));
    },
  );

  test(
    'partial raw record does not advance observer cursor; another membership cannot be observed',
    () async {
      final requests = <int>[];
      var attempt = 0;
      final peer = FakeConversationTransport(
        events: (_, params) async* {
          requests.add(params['afterCursor'] as int);
          attempt++;
          if (attempt == 1) {
            yield {
              'event': 'agent.execution.record',
              ..._reference.toJson(),
              'partIndex': 0,
              'partCount': 2,
              'record': {
                'id': 'dispatch-fixture:1',
                'cursor': 1,
                'kind': 'runtime',
                'timestamp': 0,
                'rawText': 'first half',
              },
            };
          } else {
            yield {
              'event': 'agent.execution.ready',
              ..._reference.toJson(),
              'membershipId': 'different-membership',
              'cursor': 1,
            };
          }
        },
      );
      final service = AgentConversationService(
        native: StdioConversationNativePort(
          transport: peer,
          desktopRuntime: true,
        ),
      );
      final observation = NativeConversationExecutionReader(
        service,
      ).observe(_reference);
      addTearDown(observation.dispose);
      await _flush();
      expect(observation.snapshot.records, isEmpty);
      expect(observation.snapshot.errorCode, 'execution_history_incomplete');
      observation.reconnect();
      await _flush();
      expect(requests, [0, 0]);
      expect(observation.snapshot.errorCode, 'execution_scope_mismatch');
      expect(observation.snapshot.records, isEmpty);
    },
  );
}

final class _Source implements ConversationExecutionSource {
  final streams = <StreamController<ConversationExecutionEvent>>[];
  final requests = <int>[];
  final references = <ConversationExecutionReference>[];
  var cancelled = 0;
  final executionRunning = true;
  @override
  Stream<ConversationExecutionEvent> watchExecution(
    ConversationExecutionReference reference, {
    int afterCursor = 0,
  }) {
    references.add(reference);
    requests.add(afterCursor);
    final stream = StreamController<ConversationExecutionEvent>(
      onCancel: () {
        cancelled++;
      },
    );
    streams.add(stream);
    return stream.stream;
  }
}
