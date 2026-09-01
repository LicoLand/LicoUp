import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:licoup/src/projections/projection_consumer.dart';

/// Stream adapter for a legacy Listenable-backed projection during migration.
///
/// It performs no reduction or inference: each notification reads and emits
/// the domain's already-computed projected value.
class ListenableProjectionConsumer<T> implements ProjectionConsumer<T> {
  ListenableProjectionConsumer({
    required Listenable source,
    required T Function() read,
  }) : _source = source,
       _read = read {
    _source.addListener(_emit);
  }

  final Listenable _source;
  final T Function() _read;
  final StreamController<T> _controller = StreamController<T>.broadcast(
    sync: true,
  );
  bool _disposed = false;

  @override
  T get current => _read();

  @override
  Stream<T> get projections => _controller.stream;

  void _emit() {
    if (!_disposed) _controller.add(_read());
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _source.removeListener(_emit);
    await _controller.close();
  }
}
