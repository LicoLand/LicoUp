library;

/// Read-only projected state exposed to a renderer.
abstract interface class ProjectionSource<T> {
  T get current;

  Stream<ProjectionUpdate<T>> get changes;
}

/// One immutable projected value and its optional renderer-local cause.
final class ProjectionUpdate<T> {
  const ProjectionUpdate(this.value, {this.trace});

  final T value;
  final TraceContext? trace;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProjectionUpdate<T> &&
          other.value == value &&
          other.trace == trace;

  @override
  int get hashCode => Object.hash(value, trace);
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
