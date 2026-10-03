/// The four package facts the package center renders.
///
/// They are a pure value contract: the native package store reports them, the
/// application layer parses them, and the renderer only reads them. No renderer
/// derives a fact, and an absent capability is the same all-false value the
/// store implies when it holds no package.
///
/// Only the forward implications the store itself enforces are meaningful: an
/// active instance needs an enabled package, which needs an installed one.
/// Availability is deliberately not part of that chain — a local import is
/// installed without ever being available.
final class PackageFacts {
  const PackageFacts({
    required this.available,
    required this.installed,
    required this.enabled,
    required this.active,
  });

  /// No capability is present at all: the not-installed state.
  static const absent = PackageFacts(
    available: false,
    installed: false,
    enabled: false,
    active: false,
  );

  final bool available;
  final bool installed;
  final bool enabled;
  final bool active;

  bool get notInstalled => !installed;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PackageFacts &&
          other.available == available &&
          other.installed == installed &&
          other.enabled == enabled &&
          other.active == active;

  @override
  int get hashCode => Object.hash(available, installed, enabled, active);

  @override
  String toString() =>
      'PackageFacts(available: $available, installed: $installed, '
      'enabled: $enabled, active: $active)';
}
