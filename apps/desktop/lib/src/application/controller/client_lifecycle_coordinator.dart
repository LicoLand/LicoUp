import 'dart:async';

import 'package:flutter/foundation.dart';

enum ClientLifecyclePhase { idle, initializing, ready, failed, disposed }

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

  static final RegExp _stableId = RegExp(r'^[a-z][a-z0-9._-]*$');

  final ClientLifecycleReportSink _onReport;
  ClientLifecyclePhase _phase = ClientLifecyclePhase.idle;
  Future<void>? _initializeFuture;
  int _generation = 0;

  ClientLifecyclePhase get phase => _phase;
  bool get initialized => _phase == ClientLifecyclePhase.ready;

  Future<void> initialize({
    required List<ClientBootstrapStep> sequentialSteps,
    List<ClientBootstrapStep> backgroundSteps = const [],
    bool runBackgroundSteps = true,
    ClientBootstrapStep? finalStep,
  }) {
    if (_phase == ClientLifecyclePhase.disposed) return Future<void>.value();
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
    _phase = ClientLifecyclePhase.initializing;
    notifyListeners();
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
      _phase = ClientLifecyclePhase.ready;
      notifyListeners();
    } catch (_) {
      if (!_isCurrent(generation)) return;
      _phase = ClientLifecyclePhase.failed;
      _onReport(
        const ClientLifecycleReport(
          code: 'client_initialize_failed',
          stepId: 'sequential_bootstrap',
        ),
      );
      notifyListeners();
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
      _onReport(
        ClientLifecycleReport(
          code: 'client_background_step_failed',
          stepId: _safeStepId(step.id),
        ),
      );
    }
  }

  bool _isCurrent(int generation) =>
      _phase != ClientLifecyclePhase.disposed && generation == _generation;

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
    _phase = ClientLifecyclePhase.disposed;
    super.dispose();
  }
}
