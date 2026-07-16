import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:flutter_client/src/contracts/routing/routing_module_registration.dart';
import 'package:flutter_client/src/contracts/routing/routing_policy_schema.dart';
import 'package:flutter_client/src/contracts/routing/task_route_coordinator_port.dart';

typedef RoutingRegistrationFactory = RoutingModuleRegistration Function();
typedef RoutingPolicyLoadedSink =
    void Function(
      RoutingPolicyDocument policy,
      TaskRouteCoordinatorPort? coordinator,
    );
typedef RoutingModuleErrorSink = void Function(String errorCode);

/// Owns routing registration activation, policy subscription, and shutdown.
final class RoutingModuleLifecycleController extends ChangeNotifier {
  RoutingModuleLifecycleController({
    required RoutingRegistrationFactory createRegistration,
    required RoutingPolicyLoadedSink onPolicyLoaded,
    required RoutingModuleErrorSink onError,
  }) : _createRegistration = createRegistration,
       _onPolicyLoaded = onPolicyLoaded,
       _onError = onError;

  final RoutingRegistrationFactory _createRegistration;
  final RoutingPolicyLoadedSink _onPolicyLoaded;
  final RoutingModuleErrorSink _onError;
  RoutingModuleRegistration? _registration;
  StreamSubscription<RoutingPolicyStoreEvent>? _subscription;
  Future<RoutingModuleRegistration>? _activationFuture;
  bool _disposed = false;

  RoutingModuleRegistration? get registration => _registration;
  bool get available =>
      _registration?.isEnabled == true && _registration?.isReady == true;

  Future<RoutingModuleRegistration> ensureReady() {
    final current = _registration;
    if (current != null && (current.isReady || !current.isEnabled)) {
      return Future.value(current);
    }
    final active = _activationFuture;
    if (active != null) return active;
    late final Future<RoutingModuleRegistration> activation;
    activation = _activate().whenComplete(() {
      if (identical(_activationFuture, activation)) {
        _activationFuture = null;
      }
    });
    _activationFuture = activation;
    return activation;
  }

  Future<RoutingModuleRegistration> _activate() async {
    if (_disposed) throw StateError('routing_module_disposed');
    final registration = _createRegistration();
    await registration.activate();
    if (_disposed) {
      await registration.deactivate();
      throw StateError('routing_module_disposed');
    }
    await bind(registration);
    notifyListeners();
    return registration;
  }

  void replaceRegistration(RoutingModuleRegistration? registration) {
    _registration = registration;
    notifyListeners();
  }

  Future<void> bind(RoutingModuleRegistration registration) async {
    if (_disposed) return;
    await _subscription?.cancel();
    _registration = registration;
    _subscription = registration.policyEvents.listen(_handleEvent);
    _onPolicyLoaded(registration.activePolicy, registration.coordinator);
  }

  Future<void> unbind() async {
    await _subscription?.cancel();
    _subscription = null;
  }

  void _handleEvent(RoutingPolicyStoreEvent event) {
    if (_disposed) return;
    switch (event) {
      case RoutingPolicyStoreLoaded(:final document) ||
          RoutingPolicyStoreReloaded(:final document):
        _onPolicyLoaded(document, _registration?.coordinator);
      case RoutingPolicyStoreValidationFailed():
        _onError('routing_policy_validation_failed');
    }
    notifyListeners();
  }

  Future<void> shutdown() async {
    if (_disposed) return;
    _disposed = true;
    await unbind();
    final registration = _registration;
    _registration = null;
    if (registration != null) await registration.deactivate();
  }

  @override
  void dispose() {
    unawaited(shutdown());
    super.dispose();
  }
}
