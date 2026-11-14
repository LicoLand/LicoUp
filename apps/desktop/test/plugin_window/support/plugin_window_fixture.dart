import 'dart:async';

import 'package:licoup/src/contracts/plugin_window_host_models.dart';
import 'package:licoup/src/contracts/plugin_window_host_port.dart';

PluginWindowManifest pluginManifest(
  String id, {
  String name = 'Sketch Board',
  PluginPublisher publisher = PluginPublisher.official,
  List<String> network = const [],
  PluginClipboardAccess clipboard = PluginClipboardAccess.none,
  List<String> capabilities = const ['notes.read'],
}) => PluginWindowManifest(
  id: id,
  name: name,
  publisher: publisher,
  entry: PluginWindowBundleEntry('index.html'),
  permissions: PluginWindowPermissions(
    network: network,
    clipboard: clipboard,
    capabilities: capabilities,
  ),
);

/// Scripted session: the test drives its states and bridge requests and
/// reads back what the host answered.
final class FakePluginWindowSession implements PluginWindowSession {
  FakePluginWindowSession(this.pluginId);

  @override
  final String pluginId;

  final StreamController<PluginWindowState> _states = StreamController();
  final StreamController<PluginBridgeRequest> _requests = StreamController();

  final List<(String, PluginBridgeResponse)> responses = [];
  final List<PluginPermissionDecision> decisions = [];
  int reloads = 0;
  int closes = 0;
  bool failActions = false;

  void emit(PluginWindowState state) => _states.add(state);

  void emitError(Object error) => _states.addError(error);

  void request(PluginBridgeRequest request) => _requests.add(request);

  @override
  Stream<PluginWindowState> get states => _states.stream;

  @override
  Stream<PluginBridgeRequest> get requests => _requests.stream;

  @override
  Future<void> respond(String requestId, PluginBridgeResponse response) async {
    if (failActions) throw StateError('adapter_failed');
    responses.add((requestId, response));
  }

  @override
  Future<void> reload() async {
    if (failActions) throw StateError('adapter_failed');
    reloads += 1;
  }

  @override
  Future<void> decidePermission(PluginPermissionDecision decision) async {
    if (failActions) throw StateError('adapter_failed');
    decisions.add(decision);
  }

  @override
  Future<void> close() async {
    closes += 1;
  }
}

/// Scripted host port: the test publishes the catalog and inspects the
/// sessions the host opened.
final class FakePluginWindowHostPort implements PluginWindowHostPort {
  final StreamController<List<PluginWindowManifest>> _catalog =
      StreamController();
  final Map<String, FakePluginWindowSession> sessions = {};
  int opens = 0;
  bool failOpen = false;

  void publish(List<PluginWindowManifest> catalog) => _catalog.add(catalog);

  void failCatalog() => _catalog.addError(StateError('catalog_failed'));

  @override
  Stream<List<PluginWindowManifest>> watchCatalog() => _catalog.stream;

  @override
  PluginWindowSession open(String pluginId) {
    opens += 1;
    if (failOpen) throw StateError('adapter_failed');
    return sessions[pluginId] = FakePluginWindowSession(pluginId);
  }

  Future<void> close() => _catalog.close();
}
