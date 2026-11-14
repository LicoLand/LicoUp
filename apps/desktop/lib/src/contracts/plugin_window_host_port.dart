import 'package:licoup/src/contracts/plugin_window_host_models.dart';

/// Reserved port of the WebView plugin window host.
///
/// Built-in apps never use it; only installed UI plugins do. A native
/// adapter supplies the catalog of installed plugin manifests and one
/// session per open window. The session's content area is a platform view
/// named by [PluginWindowReady.content].
abstract interface class PluginWindowHostPort {
  /// Installed UI plugins; emits the current catalog on listen and again on
  /// every install, update or removal.
  Stream<List<PluginWindowManifest>> watchCatalog();

  /// Opens a window session for [pluginId]. Platforms without an adapter
  /// return a session whose only state is [PluginWindowUnsupported].
  PluginWindowSession open(String pluginId);
}

/// One open plugin window.
abstract interface class PluginWindowSession {
  String get pluginId;

  /// Session states; emits the current state on listen.
  Stream<PluginWindowState> get states;

  /// Bridge requests from the plugin. The host answers each one exactly once
  /// through [respond].
  Stream<PluginBridgeRequest> get requests;

  Future<void> respond(String requestId, PluginBridgeResponse response);

  Future<void> reload();

  /// Answers the pending [PluginWindowPermissionRequest]; ignored when no
  /// request is pending.
  Future<void> decidePermission(PluginPermissionDecision decision);

  /// Releases the platform view and the session. Idempotent.
  Future<void> close();
}

/// Placeholder adapter shipped until the native WebView adapters land: no
/// installed plugins, and every session reports [PluginWindowUnsupported].
final class UnsupportedPluginWindowHostPort implements PluginWindowHostPort {
  const UnsupportedPluginWindowHostPort();

  @override
  Stream<List<PluginWindowManifest>> watchCatalog() =>
      Stream<List<PluginWindowManifest>>.value(const <PluginWindowManifest>[]);

  @override
  PluginWindowSession open(String pluginId) =>
      _UnsupportedPluginWindowSession(pluginId);
}

final class _UnsupportedPluginWindowSession implements PluginWindowSession {
  _UnsupportedPluginWindowSession(this.pluginId);

  @override
  final String pluginId;

  @override
  Stream<PluginWindowState> get states =>
      Stream<PluginWindowState>.value(const PluginWindowUnsupported());

  @override
  Stream<PluginBridgeRequest> get requests =>
      const Stream<PluginBridgeRequest>.empty();

  @override
  Future<void> respond(String requestId, PluginBridgeResponse response) =>
      Future<void>.value();

  @override
  Future<void> reload() => Future<void>.value();

  @override
  Future<void> decidePermission(PluginPermissionDecision decision) =>
      Future<void>.value();

  @override
  Future<void> close() => Future<void>.value();
}
