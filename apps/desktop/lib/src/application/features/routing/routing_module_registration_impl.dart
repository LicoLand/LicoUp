import 'dart:io';

import 'package:flutter_client/src/application/features/routing/routing_module_flags.dart';
import 'package:flutter_client/src/backend/features/routing/services/policy_store.dart';
import 'package:flutter_client/src/backend/features/routing/services/route_history_store.dart';
import 'package:flutter_client/src/contracts/routing/routing_module_registration.dart';
import 'package:flutter_client/src/contracts/routing/routing_policy_schema.dart';
import 'package:path/path.dart' as p;

/// Default registration for the optional multi-agent routing module.
class DefaultRoutingModuleRegistration implements RoutingModuleRegistration {
  DefaultRoutingModuleRegistration({
    required Directory rootDirectory,
    Map<String, String>? settings,
    bool included = kRoutingModuleIncluded,
    bool initiallyEnabled = true,
  }) : _rootDirectory = rootDirectory,
       _settings = settings ?? <String, String>{},
       _included = included,
       _runtimeEnabled = initiallyEnabled;

  final Directory _rootDirectory;
  final Map<String, String> _settings;
  final bool _included;

  bool _runtimeEnabled;
  bool _active = false;
  FileRoutingPolicyStore? _policyStore;
  RouteHistoryStore? _historyStore;

  FileRoutingPolicyStore? get policyStore => _policyStore;
  RouteHistoryStore? get historyStore => _historyStore;
  Map<String, String> get settingsView => Map.unmodifiable(_settings);

  @override
  bool get isEnabled => _included && _runtimeEnabled;

  @override
  bool get isReady => isEnabled && _active && _policyStore != null;

  @override
  Future<void> activate() async {
    if (!_included || !_runtimeEnabled) {
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
    _historyStore = RouteHistoryStore(rootDirectory: _rootDirectory);
    _active = true;
  }

  @override
  Future<void> deactivate() async {
    if (!_active) {
      _runtimeEnabled = false;
      _settings['routing.enabled'] = 'false';
      return;
    }
    await _policyStore?.dispose();
    _policyStore = null;
    _historyStore = null;
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
  Future<void> enable() async {
    if (!_included) {
      return;
    }
    _runtimeEnabled = true;
    await activate();
  }

  RoutingPolicyDocument get activePolicy =>
      _policyStore?.active ?? emptyRoutingPolicyDocument;
}
