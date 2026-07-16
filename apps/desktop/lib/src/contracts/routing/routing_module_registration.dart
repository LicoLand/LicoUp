import 'package:flutter_client/src/contracts/routing/routing_policy_schema.dart';
import 'package:flutter_client/src/contracts/routing/task_route_coordinator_port.dart';

abstract class RoutingModuleRegistration {
  bool get isIncluded;
  bool get isEnabled;
  bool get isReady;
  TaskRouteCoordinatorPort? get coordinator;
  RoutingPolicyDocument get activePolicy;
  Stream<RoutingPolicyStoreEvent> get policyEvents;

  Future<void> activate();
  Future<void> deactivate();
  Future<void> unload();
  Future<void> enable();
  Future<void> savePolicy(RoutingPolicyDocument policy);
  Future<void> clearPolicy();
}
