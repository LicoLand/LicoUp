import 'package:flutter_client/src/application/features/routing/controller/task_route_coordinator.dart';
import 'package:flutter_client/src/contracts/routing/routing_policy_schema.dart';

abstract class RoutingModuleRegistration {
  bool get isIncluded;
  bool get isEnabled;
  bool get isReady;
  TaskRouteCoordinator? get coordinator;
  RoutingPolicyDocument get activePolicy;
  Stream<RoutingPolicyStoreEvent> get policyEvents;

  Future<void> activate();
  Future<void> deactivate();
  Future<void> unload();
  Future<void> enable();
  Future<void> savePolicy(RoutingPolicyDocument policy);
  Future<void> clearPolicy();
}
