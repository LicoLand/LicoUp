/// Renderer-facing port for the durable self-mascot identity
/// (`self-mascot-identity.json`).
///
/// The mascot surfaces depend on this port; the platform layer ships the
/// file-backed implementation without naming it here, and the composition
/// root adapts one onto the other (`PlatformSelfMascotStoreAdapter`). The
/// `portableData` argument stays an opaque [Object] so the port never names
/// the platform data-root type.
abstract class SelfMascotStore {
  const SelfMascotStore();

  /// The last mascot id resolved by the installed store in this process.
  ///
  /// The composition adapter updates this on every completed load or save so
  /// a remounting surface can start from the known identity synchronously
  /// instead of re-seeding a different random face. Test doubles never touch
  /// it, keeping widget tests isolated from each other.
  static String? lastKnownId;

  /// The stored mascot id, or null when no document exists yet — the caller
  /// initializes the first-run random pick and persists it once, so the same
  /// face stays fixed on every later launch.
  Future<String?> load(Object portableData);

  /// Persists [mascotId] with an atomic replace.
  Future<void> save(Object portableData, String mascotId);
}
