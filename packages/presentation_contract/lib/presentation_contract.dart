library;

/// Read-only projected state exposed to a renderer.
abstract interface class ProjectionSource<T> {
  T get current;

  Stream<T> get changes;
}

/// Non-replayed, one-shot effects exposed to a renderer.
abstract interface class EffectSource<E> {
  Stream<E> get effects;
}

/// Fire-and-forget semantic input accepted from a renderer.
abstract interface class IntentSink<I> {
  void send(I intent);
}

/// Optional opaque local causal context carried across presentation operations.
final class TraceContext {
  const TraceContext({this.traceId});

  final String? traceId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TraceContext && other.traceId == traceId;

  @override
  int get hashCode => traceId.hashCode;
}
