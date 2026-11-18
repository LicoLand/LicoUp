import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/contracts/plugin_window_host_models.dart';
import 'package:licoup/src/contracts/plugin_window_host_port.dart';
import 'package:licoup/src/presentation/plugin_window/plugin_window_effect.dart';
import 'package:licoup/src/presentation/plugin_window/plugin_window_intent.dart';
import 'package:licoup/src/presentation/plugin_window/plugin_window_projection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

/// Plugin window source over the reserved host port.
///
/// Observes the installed-plugin catalog, owns one host session per open
/// window, and enforces the message-bridge policy: a request is answered
/// only for a capability the manifest declares and within the payload
/// bound. No LicoUp capability is served to plugins yet, so declared
/// requests are refused with [pluginCapabilityUnavailable].
final class PluginWindowPresentationSource
    implements
        ProjectionSource<PluginWindowProjection>,
        IntentSink<PluginWindowIntent>,
        EffectSource<PluginWindowEffect> {
  PluginWindowPresentationSource({required PluginWindowHostPort port})
    : _port = port {
    _catalogSubscription = _port.watchCatalog().listen(
      _acceptCatalog,
      onError: _acceptCatalogError,
    );
  }

  final PluginWindowHostPort _port;
  late final StreamSubscription<List<PluginWindowManifest>>
  _catalogSubscription;
  final StreamController<ProjectionUpdate<PluginWindowProjection>> _changes =
      StreamController<ProjectionUpdate<PluginWindowProjection>>.broadcast(
        sync: true,
      );
  final StreamController<PluginWindowEffect> _effects =
      StreamController<PluginWindowEffect>.broadcast(sync: true);

  PresentationPhase _phase = PresentationPhase.loading;
  List<PluginWindowManifest> _catalog = const [];
  final Map<String, _OpenWindow> _windows = <String, _OpenWindow>{};
  PluginWindowProjection _current = PluginWindowProjection.loading();
  bool _disposed = false;

  @override
  PluginWindowProjection get current => _current;

  @override
  Stream<ProjectionUpdate<PluginWindowProjection>> get changes =>
      _changes.stream;

  @override
  Stream<PluginWindowEffect> get effects => _effects.stream;

  @override
  void send(PluginWindowIntent intent) {
    if (_disposed) return;
    switch (intent) {
      case OpenPluginWindow(:final pluginId):
        _open(pluginId, intent.trace);
      case ReloadPluginWindow(:final pluginId):
        final window = _windows[pluginId];
        if (window != null) unawaited(_guard(window.session.reload));
      case ClosePluginWindow(:final pluginId):
        unawaited(_close(pluginId));
      case DecidePluginWindowPermission(:final pluginId, :final decision):
        final window = _windows[pluginId];
        if (window == null ||
            window.projection.status != PluginWindowStatus.permissionRequest) {
          return;
        }
        unawaited(_guard(() => window.session.decidePermission(decision)));
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _catalogSubscription.cancel();
    final windows = _windows.values.toList(growable: false);
    _windows.clear();
    for (final window in windows) {
      await window.dispose();
    }
    await _changes.close();
    await _effects.close();
  }

  void _acceptCatalog(List<PluginWindowManifest> catalog) {
    if (_disposed) return;
    _phase = PresentationPhase.ready;
    _catalog = List<PluginWindowManifest>.unmodifiable(catalog);
    final installed = {for (final manifest in _catalog) manifest.id: manifest};
    for (final entry in _windows.entries.toList(growable: false)) {
      final manifest = installed[entry.key];
      if (manifest == null) {
        unawaited(_close(entry.key));
      } else {
        // An update can narrow the declared permissions of an open window;
        // bridge checks follow the installed manifest.
        entry.value.manifest = manifest;
      }
    }
    _emit();
  }

  void _acceptCatalogError(Object error) {
    if (_disposed) return;
    _phase = PresentationPhase.failed;
    _emit();
  }

  void _open(String pluginId, TraceContext? trace) {
    if (_windows.containsKey(pluginId)) return;
    PluginWindowManifest? manifest;
    for (final candidate in _catalog) {
      if (candidate.id == pluginId) {
        manifest = candidate;
        break;
      }
    }
    if (manifest == null) {
      _effects.add(
        PluginWindowOpenRejected(
          pluginId,
          pluginWindowNotInstalled,
          trace: trace,
        ),
      );
      return;
    }
    final PluginWindowSession session;
    try {
      session = _port.open(pluginId);
    } catch (_) {
      _effects.add(
        PluginWindowOpenRejected(pluginId, pluginWindowFailed, trace: trace),
      );
      return;
    }
    final window = _OpenWindow(
      manifest: manifest,
      session: session,
      projection: PluginWindowSessionProjection(
        pluginId: pluginId,
        status: PluginWindowStatus.loading,
      ),
    );
    _windows[pluginId] = window;
    window.stateSubscription = session.states.listen(
      (state) => _acceptState(window, state),
      onError: (Object _) => _acceptState(window, PluginWindowError('')),
    );
    window.requestSubscription = session.requests.listen(
      (request) => _answer(window, request),
      onError: (Object _) {},
    );
    _emit();
  }

  void _acceptState(_OpenWindow window, PluginWindowState state) {
    if (_disposed || !identical(_windows[window.manifest.id], window)) return;
    window.projection = _sessionProjection(window.manifest.id, state);
    _emit();
  }

  void _answer(_OpenWindow window, PluginBridgeRequest request) {
    if (_disposed || !identical(_windows[window.manifest.id], window)) return;
    final code =
        !window.manifest.permissions.declaresCapability(request.capability)
        ? pluginCapabilityUndeclared
        : !request.withinLimit
        ? pluginBridgePayloadTooLarge
        : pluginCapabilityUnavailable;
    unawaited(
      _guard(
        () => window.session.respond(
          request.requestId,
          PluginBridgeFailure(code),
        ),
      ),
    );
  }

  Future<void> _close(String pluginId) async {
    final window = _windows.remove(pluginId);
    if (window == null) return;
    _emit();
    await window.dispose();
  }

  /// Adapter failures on reload, decide and respond are reported through
  /// the session's state stream; the returned future carries nothing the
  /// renderer could act on.
  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {}
  }

  void _emit() {
    if (_disposed) return;
    final next = PluginWindowProjection(
      phase: _phase,
      catalog: _catalog,
      sessions: [for (final window in _windows.values) window.projection],
    );
    if (next == _current) return;
    _current = next;
    _changes.add(ProjectionUpdate<PluginWindowProjection>(next));
  }
}

PluginWindowSessionProjection _sessionProjection(
  String pluginId,
  PluginWindowState state,
) => switch (state) {
  PluginWindowLoading(:final progress) => PluginWindowSessionProjection(
    pluginId: pluginId,
    status: PluginWindowStatus.loading,
    progress: progress,
  ),
  PluginWindowReady(:final content) => PluginWindowSessionProjection(
    pluginId: pluginId,
    status: PluginWindowStatus.ready,
    content: content,
  ),
  PluginWindowPermissionRequest(:final capability, :final detail) =>
    PluginWindowSessionProjection(
      pluginId: pluginId,
      status: PluginWindowStatus.permissionRequest,
      permissionCapability: capability,
      permissionDetail: detail,
    ),
  PluginWindowError(:final code) => PluginWindowSessionProjection(
    pluginId: pluginId,
    status: PluginWindowStatus.error,
    errorCode: code,
  ),
  PluginWindowOffline() => PluginWindowSessionProjection(
    pluginId: pluginId,
    status: PluginWindowStatus.offline,
  ),
  PluginWindowUnsupported() => PluginWindowSessionProjection(
    pluginId: pluginId,
    status: PluginWindowStatus.unsupported,
  ),
};

final class _OpenWindow {
  _OpenWindow({
    required this.manifest,
    required this.session,
    required this.projection,
  });

  PluginWindowManifest manifest;
  final PluginWindowSession session;
  PluginWindowSessionProjection projection;
  StreamSubscription<PluginWindowState>? stateSubscription;
  StreamSubscription<PluginBridgeRequest>? requestSubscription;

  Future<void> dispose() async {
    await stateSubscription?.cancel();
    await requestSubscription?.cancel();
    try {
      await session.close();
    } catch (_) {}
  }
}
