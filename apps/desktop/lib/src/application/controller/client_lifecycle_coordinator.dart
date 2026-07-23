import 'dart:async';

import 'package:flutter/foundation.dart';

enum ClientLifecyclePhase { idle, initializing, ready, failed, disposed }

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
final class ClientLifecycleCoordinator extends ChangeNotifier {
  ClientLifecycleCoordinator({required ClientLifecycleReportSink onReport})
    : _onReport = onReport;

  static final RegExp _stableId = RegExp(r'^[a-z][a-z0-9._-]{0,63}$');

  final ClientLifecycleReportSink _onReport;
  ClientLifecyclePhase _phase = ClientLifecyclePhase.idle;
  ClientLifecycleProjection _projection = const ClientLifecycleProjection._(
    ClientLifecyclePhase.idle,
  );
  Future<void>? _initializeFuture;
  int _generation = 0;

  ClientLifecycleProjection get projection => _projection;

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
    if (!_transition(ClientLifecyclePhase.initializing, stepId: 'initialize')) {
      return;
    }
    try {
      for (final step in sequentialSteps) {
        await step.action();
        if (!_isCurrent(generation)) return;
      }
      if (runBackgroundSteps && backgroundSteps.isNotEmpty) {
        await Future.wait<void>([
          for (final step in backgroundSteps)
            _runBackgroundStep(step, generation),
        ]);
      }
      if (!_isCurrent(generation)) return;
      if (finalStep != null) {
        await finalStep.action();
        if (!_isCurrent(generation)) return;
      }
      _transition(ClientLifecyclePhase.ready, stepId: 'initialize_complete');
    } catch (_) {
      if (!_isCurrent(generation)) return;
      _transition(ClientLifecyclePhase.failed, stepId: 'initialize_failed');
      _report(
        const ClientLifecycleReport(
          code: 'client_initialize_failed',
          stepId: 'sequential_bootstrap',
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

  bool _transition(ClientLifecyclePhase next, {required String stepId}) {
    if (!_legalTransitions[_phase]!.contains(next)) {
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
    notifyListeners();
    return true;
  }

  void _report(ClientLifecycleReport report) {
    _onReport(report);
  }

  static const Map<ClientLifecyclePhase, Set<ClientLifecyclePhase>>
  _legalTransitions = {
    ClientLifecyclePhase.idle: {
      ClientLifecyclePhase.initializing,
      ClientLifecyclePhase.disposed,
    },
    ClientLifecyclePhase.initializing: {
      ClientLifecyclePhase.ready,
      ClientLifecyclePhase.failed,
      ClientLifecyclePhase.disposed,
    },
    ClientLifecyclePhase.ready: {ClientLifecyclePhase.disposed},
    ClientLifecyclePhase.failed: {
      ClientLifecyclePhase.initializing,
      ClientLifecyclePhase.disposed,
    },
    ClientLifecyclePhase.disposed: {},
  };

  @visibleForTesting
  ClientLifecycleReport transitionForTesting(
    ClientLifecyclePhase next, {
    required String stepId,
  }) {
    final safeStepId = _safeStepId(stepId);
    if (_legalTransitions[_phase]!.contains(next)) {
      _transition(next, stepId: safeStepId);
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
    _transition(ClientLifecyclePhase.disposed, stepId: 'dispose');
    super.dispose();
  }
}
