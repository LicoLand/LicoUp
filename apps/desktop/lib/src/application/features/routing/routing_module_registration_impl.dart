import 'dart:async';
import 'dart:io';

import 'package:flutter_client/src/application/features/routing/controller/task_route_coordinator.dart';
import 'package:flutter_client/src/application/features/routing/routing_module_flags.dart';
import 'package:flutter_client/src/backend/features/routing/services/policy_store.dart';
import 'package:flutter_client/src/backend/features/routing/services/route_history_store.dart';
import 'package:flutter_client/src/backend/features/routing/services/route_session_binding_store.dart';
import 'package:flutter_client/src/contracts/routing/routing_module_registration.dart';
import 'package:flutter_client/src/contracts/routing/routing_policy_schema.dart';
import 'package:flutter_client/src/contracts/routing/task_route_coordinator_port.dart';
import 'package:path/path.dart' as p;

/// Default registration for the optional multi-agent routing module.
class DefaultRoutingModuleRegistration implements RoutingModuleRegistration {
  DefaultRoutingModuleRegistration({
    required Directory rootDirectory,
    Map<String, String>? settings,
    bool initiallyEnabled = true,
  }) : _rootDirectory = rootDirectory,
       _settings = settings ?? <String, String>{},
       _runtimeEnabled = initiallyEnabled;

  final Directory _rootDirectory;
  final Map<String, String> _settings;
  bool _runtimeEnabled;
  bool _active = false;
  FileRoutingPolicyStore? _policyStore;
  RouteHistoryStore? _historyStore;
  ProtectedRouteSessionBindingStore? _sessionBindingStore;
  TaskRouteCoordinatorPort? _coordinator;
  StreamSubscription<RoutingPolicyStoreEvent>? _policySubscription;
  final StreamController<RoutingPolicyStoreEvent> _policyEvents =
      StreamController<RoutingPolicyStoreEvent>.broadcast();

  FileRoutingPolicyStore? get policyStore => _policyStore;
  RouteHistoryStore? get historyStore => _historyStore;
  @override
  TaskRouteCoordinatorPort? get coordinator => _coordinator;
  Map<String, String> get settingsView => Map.unmodifiable(_settings);
  @override
  Stream<RoutingPolicyStoreEvent> get policyEvents => _policyEvents.stream;

  @override
  bool get isIncluded => true;

  @override
  bool get isEnabled => _runtimeEnabled;

  @override
  bool get isReady =>
      isEnabled && _active && _policyStore != null && _coordinator != null;

  @override
  Future<void> activate() async {
    if (!_runtimeEnabled) {
      return;
    }
    if (_active) {
      return;
    }
    _settings['routing.enabled'] = 'true';
    _settings.putIfAbsent(
      'routing.policyPath',
      () => defaultRoutingPolicyRelativePath,
    );
    _policyStore = FileRoutingPolicyStore(rootDirectory: _rootDirectory);
    await _policyStore!.load();
    final policyEvents = await _policyStore!.startWatching();
    _policySubscription = policyEvents.listen(_policyEvents.add);
    _historyStore = RouteHistoryStore(rootDirectory: _rootDirectory);
    _sessionBindingStore = ProtectedRouteSessionBindingStore(
      rootDirectory: _rootDirectory,
    );
    _coordinator = TaskRouteCoordinator(
      historyStore: _historyStore!,
      sessionBindingStore: _sessionBindingStore!,
    );
    _active = true;
  }

  @override
  Future<void> deactivate() async {
    if (!_active) {
      _runtimeEnabled = false;
      _settings['routing.enabled'] = 'false';
      return;
    }
    await _policySubscription?.cancel();
    _policySubscription = null;
    await _policyStore?.dispose();
    _policyStore = null;
    _historyStore = null;
    _sessionBindingStore = null;
    _coordinator = null;
    _active = false;
    _runtimeEnabled = false;
    _settings['routing.enabled'] = 'false';
  }

  @override
  Future<void> unload() async {
    await deactivate();
    for (final key in routingModuleSettingsKeys) {
      _settings.remove(key);
    }
    final stateDir = Directory(
      p.join(_rootDirectory.path, routingModuleStateDirectory),
    );
    if (await stateDir.exists()) {
      await stateDir.delete(recursive: true);
    }
  }

  /// Re-enable after a prior deactivate/unload (clean start).
  @override
  Future<void> enable() async {
    _runtimeEnabled = true;
    await activate();
  }

  @override
  RoutingPolicyDocument get activePolicy =>
      _policyStore?.active ?? emptyRoutingPolicyDocument;

  @override
  Future<void> savePolicy(RoutingPolicyDocument policy) async {
    final store = _policyStore;
    if (!isReady || store == null) {
      throw StateError('Routing module is not ready.');
    }
    await store.save(policy);
  }

  @override
  Future<void> clearPolicy() async {
    final store = _policyStore;
    if (!isReady || store == null) {
      throw StateError('Routing module is not ready.');
    }
    await store.clear();
  }
}
