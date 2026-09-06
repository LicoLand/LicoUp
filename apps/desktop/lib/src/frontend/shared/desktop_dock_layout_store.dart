import 'package:licoup/src/contracts/presentation/desktop_dock_layout.dart';

/// Renderer-facing port for the Desktop dock layout store
/// (`desktop-dock-layout.json`).
///
/// The dock model depends on this port; the platform layer ships the
/// file-backed implementation without naming it here, and the composition
/// root adapts one onto the other (`PlatformDesktopDockLayoutStoreAdapter`).
/// The `portableData` argument stays an opaque [Object] so the port never
/// names the platform data-root type.
abstract class DesktopDockLayoutStore {
  const DesktopDockLayoutStore();

  /// The stored dock layout; a missing, malformed, or foreign-version
  /// document yields the default empty dock instead of failing startup.
  Future<DesktopDockLayoutSnapshot> load(Object portableData);

  /// Persists [snapshot] with an atomic replace.
  Future<void> save(Object portableData, DesktopDockLayoutSnapshot snapshot);
}
