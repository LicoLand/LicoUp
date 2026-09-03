import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/projections/adapters/legacy_projection_consumer_source_adapter.dart';
import 'package:licoup/src/projections/projection_consumer.dart';

void main() {
  test(
    'legacy adapter exposes reads while concrete owner keeps lifecycle',
    () async {
      final consumer = _FakeConsumer(3);
      final source = LegacyProjectionConsumerSourceAdapter<int>(consumer);
      final values = <int>[];
      final subscription = source.changes.listen(values.add);

      expect(source.current, 3);
      consumer.publish(5);
      expect(values, <int>[5]);
      expect(consumer.disposeCount, 0);

      await subscription.cancel();
      await consumer.dispose();
      expect(consumer.disposeCount, 1);
    },
  );
}

final class _FakeConsumer implements ProjectionConsumer<int> {
  _FakeConsumer(this._current);

  final StreamController<int> _values = StreamController<int>.broadcast(
    sync: true,
  );
  int _current;
  int disposeCount = 0;

  @override
  int get current => _current;

  @override
  Stream<int> get projections => _values.stream;

  void publish(int value) {
    _current = value;
    _values.add(value);
  }

  @override
  Future<void> dispose() async {
    disposeCount += 1;
    await _values.close();
  }
}
