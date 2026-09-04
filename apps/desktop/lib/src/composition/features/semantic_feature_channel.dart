import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';
import 'package:licoup/src/projections/close_broadcast_controller.dart';

typedef SemanticIntentHandler<I> = FutureOr<void> Function(I intent);

/// Composition-owned fire-and-forget bridge from a semantic renderer intent
/// to its concrete Application owner.
final class SemanticIntentChannel<I> implements IntentSink<I> {
  SemanticIntentChannel(this._handle);

  final SemanticIntentHandler<I> _handle;

  @override
  void send(I intent) {
    final result = _handle(intent);
    if (result is Future<void>) unawaited(result);
  }
}

/// Composition-owned, non-replayed one-shot effect lane.
final class SemanticEffectChannel<E> implements EffectSource<E> {
  final StreamController<E> _controller = StreamController<E>.broadcast(
    sync: true,
  );
  bool _disposed = false;

  @override
  Stream<E> get effects => _controller.stream;

  void emit(E effect) {
    if (!_disposed) _controller.add(effect);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await closeBroadcastController(_controller);
  }
}
