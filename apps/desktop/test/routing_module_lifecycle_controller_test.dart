import 'dart:async';

import 'package:flutter_client/src/application/features/routing/controller/routing_module_lifecycle_controller.dart';
import 'package:flutter_client/src/contracts/routing/routing_module_registration.dart';
import 'package:flutter_client/src/contracts/routing/routing_policy_schema.dart';
import 'package:flutter_client/src/contracts/routing/task_route_coordinator_port.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'activation is single-flight and policy events use typed callbacks',
    () async {
      final registration = _FakeRoutingRegistration();
      final policies = <RoutingPolicyDocument>[];
      final errors = <String>[];
      final controller = RoutingModuleLifecycleController(
        createRegistration: () => registration,
        onPolicyLoaded: (policy, _) => policies.add(policy),
        onError: errors.add,
      );
      addTearDown(controller.dispose);

      final first = controller.ensureReady();
      final second = controller.ensureReady();
      expect(identical(first, second), isTrue);
      await first;
      expect(registration.activateCalls, 1);
      expect(policies, hasLength(1));

      registration.events.add(
        RoutingPolicyStoreReloaded(registration.activePolicy),
      );
      registration.events.add(
        const RoutingPolicyStoreValidationFailed(
          RoutingPolicyValidationError(
            path: 'private/path',
            message: 'private detail',
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(policies, hasLength(2));
      expect(errors, ['routing_policy_validation_failed']);
      expect(errors.toString(), isNot(contains('private detail')));
    },
  );

  test('shutdown cancels the subscription and deactivates once', () async {
    final registration = _FakeRoutingRegistration();
    final controller = RoutingModuleLifecycleController(
      createRegistration: () => registration,
      onPolicyLoaded: (_, _) {},
      onError: (_) {},
    );
    await controller.ensureReady();
    await controller.shutdown();
    await controller.shutdown();
    expect(registration.deactivateCalls, 1);
    controller.dispose();
  });
}

final class _FakeRoutingRegistration implements RoutingModuleRegistration {
  final StreamController<RoutingPolicyStoreEvent> events =
      StreamController<RoutingPolicyStoreEvent>.broadcast();
  int activateCalls = 0;
  int deactivateCalls = 0;
  bool _ready = false;

  @override
  bool get isIncluded => true;

  @override
  bool get isEnabled => true;

  @override
  bool get isReady => _ready;

  @override
  TaskRouteCoordinatorPort? get coordinator => null;

  @override
  RoutingPolicyDocument get activePolicy => emptyRoutingPolicyDocument;

  @override
  Stream<RoutingPolicyStoreEvent> get policyEvents => events.stream;

  @override
  Future<void> activate() async {
    activateCalls += 1;
    _ready = true;
  }

  @override
  Future<void> deactivate() async {
    deactivateCalls += 1;
    _ready = false;
  }

  @override
  Future<void> unload() async {}

  @override
  Future<void> enable() async {}

  @override
  Future<void> savePolicy(RoutingPolicyDocument policy) async {}

  @override
  Future<void> clearPolicy() async {}
}
