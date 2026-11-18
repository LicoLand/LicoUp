import 'package:licoup/src/contracts/plugin_window_host_models.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

/// Renderer-facing state of one open plugin window.
enum PluginWindowStatus {
  loading,
  ready,
  permissionRequest,
  error,
  offline,
  unsupported,
}

final class PluginWindowSessionProjection {
  const PluginWindowSessionProjection({
    required this.pluginId,
    required this.status,
    this.progress,
    this.content,
    this.permissionCapability = '',
    this.permissionDetail = '',
    this.errorCode = '',
  });

  final String pluginId;
  final PluginWindowStatus status;

  /// Load progress while [status] is loading; null while indeterminate.
  final double? progress;

  /// The platform view while [status] is ready.
  final PluginWindowContentView? content;

  /// The capability awaiting a decision while [status] is
  /// permissionRequest.
  final String permissionCapability;
  final String permissionDetail;

  /// Stable machine code while [status] is error.
  final String errorCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PluginWindowSessionProjection &&
          other.pluginId == pluginId &&
          other.status == status &&
          other.progress == progress &&
          identical(other.content, content) &&
          other.permissionCapability == permissionCapability &&
          other.permissionDetail == permissionDetail &&
          other.errorCode == errorCode;

  @override
  int get hashCode => Object.hash(
    pluginId,
    status,
    progress,
    identityHashCode(content),
    permissionCapability,
    permissionDetail,
    errorCode,
  );
}

/// Installed UI plugins and the windows open in this session, in the order
/// they were opened.
final class PluginWindowProjection {
  PluginWindowProjection({
    required this.phase,
    Iterable<PluginWindowManifest> catalog = const [],
    Iterable<PluginWindowSessionProjection> sessions = const [],
  }) : catalog = immutablePresentationList(catalog),
       sessions = immutablePresentationList(sessions);

  PluginWindowProjection.loading() : this(phase: PresentationPhase.loading);

  /// `loading` until the host reports its first catalog; `failed` when the
  /// catalog cannot be observed.
  final PresentationPhase phase;
  final List<PluginWindowManifest> catalog;
  final List<PluginWindowSessionProjection> sessions;

  PluginWindowManifest? manifest(String pluginId) {
    for (final manifest in catalog) {
      if (manifest.id == pluginId) return manifest;
    }
    return null;
  }

  PluginWindowSessionProjection? session(String pluginId) {
    for (final session in sessions) {
      if (session.pluginId == pluginId) return session;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PluginWindowProjection &&
          other.phase == phase &&
          _sameIdentities(other.catalog, catalog) &&
          samePresentationList(other.sessions, sessions);

  @override
  int get hashCode => Object.hash(
    phase,
    Object.hashAll(catalog.map(identityHashCode)),
    Object.hashAll(sessions),
  );

  static bool _sameIdentities<T>(List<T> left, List<T> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (!identical(left[index], right[index])) return false;
    }
    return true;
  }
}
