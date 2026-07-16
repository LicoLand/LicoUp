import 'dart:async';

import 'package:flutter_client/src/contracts/routing/routing_module_registration.dart';
import 'package:flutter_client/src/contracts/routing/routing_policy_schema.dart';
import 'package:flutter_client/src/contracts/routing/task_route_coordinator_port.dart';

/// Compile-time-excluded routing boundary.
///
/// This object owns no settings, files, watchers, policy, history, or routing
/// engine. It exists only so the shared controller can keep its direct-agent
/// dispatch path without a second routing implementation.
final class ExcludedRoutingModuleRegistration
    implements RoutingModuleRegistration {
  const ExcludedRoutingModuleRegistration();

  @override
  bool get isIncluded => false;

  @override
  bool get isEnabled => false;

  @override
  bool get isReady => false;

  @override
  TaskRouteCoordinatorPort? get coordinator => null;

  @override
  RoutingPolicyDocument get activePolicy => emptyRoutingPolicyDocument;

  @override
  Stream<RoutingPolicyStoreEvent> get policyEvents => const Stream.empty();

  @override
  Future<void> activate() async {}

  @override
  Future<void> deactivate() async {}

  @override
  Future<void> unload() async {}

  @override
  Future<void> enable() async {}

  @override
  Future<void> savePolicy(RoutingPolicyDocument policy) {
    return Future<void>.error(StateError('routing_module_excluded'));
  }

  @override
  Future<void> clearPolicy() {
    return Future<void>.error(StateError('routing_module_excluded'));
  }
}
