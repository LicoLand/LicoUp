import 'dart:async';
import 'dart:collection';

import 'package:licoup/src/contracts/conversation_execution.dart';
import 'package:licoup/src/contracts/conversation_execution_port.dart';
import 'package:licoup/src/contracts/conversation_native_port.dart';

final class NativeConversationExecutionReader
    implements ConversationExecutionReader {
  const NativeConversationExecutionReader(this.source);
  final ConversationExecutionSource source;
  @override
  ConversationExecutionObservation observe(
    ConversationExecutionReference reference,
  ) => _ExecutionObservation(source, reference);
}

final class _ExecutionObservation implements ConversationExecutionObservation {
  _ExecutionObservation(this._source, this._reference) {
    reconnect();
  }
  final ConversationExecutionSource _source;
  final ConversationExecutionReference _reference;
  final _changes = StreamController<ConversationExecutionState>.broadcast(
    sync: true,
  );
  final _records = <ConversationExecutionRecord>[];
  final _ids = <String>{};
  StreamSubscription<ConversationExecutionEvent>? _subscription;
  ConversationExecutionState _snapshot = const ConversationExecutionState();
  int _cursor = 0;
  int _generation = 0;
  bool _disposed = false;

  @override
  ConversationExecutionState get snapshot => _snapshot;
  @override
  Stream<ConversationExecutionState> get changes => _changes.stream;

  @override
  void reconnect() {
    if (_disposed) return;
    final generation = ++_generation;
    final previous = _subscription;
    _subscription = null;
    _publish(loading: true, errorCode: '', observationAvailable: false);
    unawaited(() async {
      await previous?.cancel();
      if (_disposed || generation != _generation) return;
      _subscription = _source
          .watchExecution(_reference, afterCursor: _cursor)
          .listen(
            (event) {
              if (_disposed || generation != _generation) return;
              switch (event) {
                case ConversationExecutionRecordEvent(:final record):
                  if (record.cursor <= _cursor || !_ids.add(record.id)) return;
                  _cursor = record.cursor;
                  _records.add(record);
                  _publish();
                case ConversationExecutionReady():
                  if (event.reference != _reference) {
                    _publish(
                      loading: false,
                      errorCode: 'execution_scope_mismatch',
                      observationAvailable: false,
                    );
                    unawaited(_subscription?.cancel());
                    return;
                  }
                  if (event.cursor > _cursor) _cursor = event.cursor;
                  _publish(
                    loading: false,
                    status: event.status,
                    observationAvailable: event.observationAvailable,
                    terminalPayloadAvailable: event.terminalPayloadAvailable,
                  );
              }
            },
            onError: (Object error) {
              if (_disposed || generation != _generation) return;
              _publish(
                loading: false,
                observationAvailable: false,
                errorCode: error is NativeConversationException
                    ? error.code
                    : 'execution_observation_failed',
              );
            },
            onDone: () {
              if (_disposed || generation != _generation) return;
              _publish(
                loading: false,
                observationAvailable: false,
                errorCode: _snapshot.loading
                    ? 'execution_history_incomplete'
                    : _snapshot.errorCode,
              );
            },
          );
    }());
  }

  void _publish({
    bool? loading,
    String? errorCode,
    String? status,
    bool? observationAvailable,
    bool? terminalPayloadAvailable,
  }) {
    if (_disposed) return;
    _snapshot = ConversationExecutionState(
      records: _RecordPrefix(_records, _records.length),
      loading: loading ?? _snapshot.loading,
      errorCode: errorCode ?? _snapshot.errorCode,
      status: status ?? _snapshot.status,
      observationAvailable:
          observationAvailable ?? _snapshot.observationAvailable,
      terminalPayloadAvailable:
          terminalPayloadAvailable ?? _snapshot.terminalPayloadAvailable,
    );
    _changes.add(_snapshot);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    unawaited(_subscription?.cancel());
    _subscription = null;
    unawaited(_changes.close());
  }
}

/// A fixed read-only prefix of append-only records keeps each published
/// snapshot stable without copying the complete history for every new frame.
final class _RecordPrefix extends ListBase<ConversationExecutionRecord> {
  _RecordPrefix(this._source, this._length);
  final List<ConversationExecutionRecord> _source;
  final int _length;
  @override
  int get length => _length;
  @override
  set length(int value) =>
      throw UnsupportedError('read-only execution records');
  @override
  ConversationExecutionRecord operator [](int index) {
    RangeError.checkValidIndex(index, this, 'index', _length);
    return _source[index];
  }

  @override
  void operator []=(int index, ConversationExecutionRecord value) =>
      throw UnsupportedError('read-only execution records');
}
