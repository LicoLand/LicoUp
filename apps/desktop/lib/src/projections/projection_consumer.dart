abstract interface class ProjectionConsumer<T> {
  T get current;

  Stream<T> get projections;

  Future<void> dispose();
}
