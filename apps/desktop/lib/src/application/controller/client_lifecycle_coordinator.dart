import 'dart:async';

import 'package:licoup/src/application/generated/state_machines.g.dart';
import 'package:licoup/src/application/state/application_signal.dart';
export 'package:licoup/src/application/generated/state_machines.g.dart'
    show ClientLifecyclePhase;

final class ClientLifecycleProjection {
  const ClientLifecycleProjection._(this.phase);

  final ClientLifecyclePhase phase;

  bool get initialized => phase == ClientLifecyclePhase.ready;
  bool get disposed => phase == ClientLifecyclePhase.disposed;
}

final class ClientBootstrapStep {
  const ClientBootstrapStep({required this.id, required this.action});

  final String id;
  final Future<void> Function() action;
}

final class ClientLifecycleReport {
  const ClientLifecycleReport({required this.code, required this.stepId});

  final String code;
  final String stepId;
}

typedef ClientLifecycleReportSink = void Function(ClientLifecycleReport report);

/// Runs the client bootstrap once, guards stale completion after disposal, and
/// keeps failure evidence to stable step IDs and codes.
final class ClientLifecycleCoordinator extends ApplicationStateOwner {
  ClientLifecycleCoordinator({required ClientLifecycleReportSink onReport})
    : _onReport = onReport;

  static final RegExp _stableId = RegExp(r'^[a-z][a-z0-9._-]{0,63}$');

  final ClientLifecycleReportSink _onReport;
  ClientLifecyclePhase _phase = clientLifecyclePhaseInitial;
  ClientLifecycleProjection _projection = const ClientLifecycleProjection._(
    clientLifecyclePhaseInitial,
  );
  Future<void>? _initializeFuture;
  String _lastFailureStepId = '';
  int _generation = 0;

  ClientLifecycleProjection get projection => _projection;
  String get lastFailureStepId => _lastFailureStepId;

  Future<void> initialize({
    required List<ClientBootstrapStep> sequentialSteps,
    List<ClientBootstrapStep> backgroundSteps = const [],
    bool runBackgroundSteps = true,
    ClientBootstrapStep? finalStep,
  }) {
    if (_phase == ClientLifecyclePhase.disposed) {
      _report(
        const ClientLifecycleReport(
          code: 'client_lifecycle_disposed',
          stepId: 'initialize',
        ),
      );
      return Future<void>.value();
    }
    final active = _initializeFuture;
    if (active != null) return active;
    if (_phase == ClientLifecyclePhase.ready) return Future<void>.value();
    final generation = ++_generation;
    late final Future<void> initialization;
    initialization =
        _run(
          generation: generation,
          sequentialSteps: sequentialSteps,
          backgroundSteps: backgroundSteps,
          runBackgroundSteps: runBackgroundSteps,
          finalStep: finalStep,
        ).whenComplete(() {
          if (identical(_initializeFuture, initialization)) {
            _initializeFuture = null;
          }
        });
    _initializeFuture = initialization;
    return initialization;
  }

  Future<void> _run({
    required int generation,
    required List<ClientBootstrapStep> sequentialSteps,
    required List<ClientBootstrapStep> backgroundSteps,
    required bool runBackgroundSteps,
    required ClientBootstrapStep? finalStep,
  }) async {
    if (!_transition(ClientLifecycleEvent.initialize, stepId: 'initialize')) {
      return;
    }
    _lastFailureStepId = '';
    var activeStepId = 'initialize';
    try {
      for (final step in sequentialSteps) {
        activeStepId = step.id;
        await step.action();
        if (!_isCurrent(generation)) return;
      }
      if (runBackgroundSteps && backgroundSteps.isNotEmpty) {
        // Update checks and optional service warmups must not delay the
        // selected page's entry hook or the ready state. Each task owns its
        // failure report and remains active until its own work settles.
        for (final step in backgroundSteps) {
          unawaited(_runBackgroundStep(step, generation));
        }
      }
      if (!_isCurrent(generation)) return;
      if (finalStep != null) {
        activeStepId = finalStep.id;
        await finalStep.action();
        if (!_isCurrent(generation)) return;
      }
      _transition(
        ClientLifecycleEvent.initializationSucceeded,
        stepId: 'initialize_complete',
      );
    } catch (_) {
      if (!_isCurrent(generation)) return;
      _lastFailureStepId = _safeStepId(activeStepId);
      _transition(
        ClientLifecycleEvent.initializationFailed,
        stepId: _lastFailureStepId,
      );
      _report(
        ClientLifecycleReport(
          code: 'client_initialize_failed',
          stepId: _lastFailureStepId,
        ),
      );
    }
  }

  Future<void> _runBackgroundStep(
    ClientBootstrapStep step,
    int generation,
  ) async {
    try {
      await step.action();
    } catch (_) {
      if (!_isCurrent(generation)) return;
      _report(
        ClientLifecycleReport(
          code: 'client_background_step_failed',
          stepId: _safeStepId(step.id),
        ),
      );
    }
  }

  bool _isCurrent(int generation) =>
      _phase != ClientLifecyclePhase.disposed && generation == _generation;

  bool _transition(ClientLifecycleEvent event, {required String stepId}) {
    final next = transitionClientLifecyclePhase(_phase, event);
    if (next == null) {
      _report(
        ClientLifecycleReport(
          code: 'client_lifecycle_transition_invalid',
          stepId: _safeStepId(stepId),
        ),
      );
      return false;
    }
    _phase = next;
    _projection = ClientLifecycleProjection._(next);
    publishChange();
    return true;
  }

  void _report(ClientLifecycleReport report) {
    _onReport(report);
  }

  ClientLifecycleReport transitionForTesting(
    ClientLifecyclePhase next, {
    required String stepId,
  }) {
    final safeStepId = _safeStepId(stepId);
    final event = clientLifecycleEventForTransition(_phase, next);
    if (event != null) {
      _transition(event, stepId: safeStepId);
      return ClientLifecycleReport(
        code: 'client_lifecycle_transition_applied',
        stepId: safeStepId,
      );
    }
    final rejection = ClientLifecycleReport(
      code: 'client_lifecycle_transition_invalid',
      stepId: safeStepId,
    );
    _report(rejection);
    return rejection;
  }

  static String _safeStepId(String value) {
    final normalized = value.trim().toLowerCase();
    return _stableId.hasMatch(normalized)
        ? normalized
        : 'unknown_background_step';
  }

  @override
  void dispose() {
    if (_phase == ClientLifecyclePhase.disposed) return;
    _generation += 1;
    _transition(ClientLifecycleEvent.dispose, stepId: 'dispose');
    super.dispose();
  }
}
