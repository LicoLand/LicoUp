import 'dart:async';

import 'package:flutter_client/src/application/controller/client_lifecycle_coordinator.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/platform/native_client/native_rpc_priority.dart';

enum _PreloadState { pending, running, done }

final class _PreloadTask {
  _PreloadTask({required this.section, required this.action});

  final ClientSection section;
  final Future<void> Function() action;
  final Completer<void> settled = Completer<void>();
  _PreloadState state = _PreloadState.pending;
  RpcPriorityToken? token;
}

/// Preloads each section's data sequentially in the background once the
/// client is ready, so navigation lands on warm data instead of triggering
/// lazy loads on click.
///
/// Tasks run one at a time at background RPC priority with an idle gap
/// between them, so they never queue ahead of interactive commands. When the
/// user enters a section, [prioritizeSection] runs its pending task
/// immediately at foreground priority, or boosts the remainder of its
/// in-flight commands to foreground.
final class ClientSectionPreloadController {
  ClientSectionPreloadController({
    required ClientSection Function() currentSection,
    required Map<ClientSection, Future<void> Function()> tasks,
    required ClientLifecycleReportSink onReport,
    Duration interTaskDelay = const Duration(milliseconds: 300),
  }) : _currentSection = currentSection,
       _tasks = Map.unmodifiable(tasks),
       _onReport = onReport,
       _interTaskDelay = interTaskDelay;

  final ClientSection Function() _currentSection;
  final Map<ClientSection, Future<void> Function()> _tasks;
  final ClientLifecycleReportSink _onReport;
  final Duration _interTaskDelay;

  final List<_PreloadTask> _ordered = <_PreloadTask>[];
  var _started = false;
  var _disposed = false;
  var _generation = 0;

  bool get disposed => _disposed;

  /// Starts the sequential background preload. Single-flight; later calls
  /// are no-ops.
  void start() {
    if (_started || _disposed) return;
    _started = true;
    final generation = _generation;
    _ordered
      ..clear()
      ..addAll(_buildOrder());
    unawaited(_run(generation));
  }

  /// Completes when the preload task for [section] settles, whether it
  /// succeeded or failed. Returns immediately when the task is unknown or
  /// the preloader is not running.
  Future<void> awaitSection(ClientSection section) {
    if (_disposed || !_started) return Future<void>.value();
    for (final task in _ordered) {
      if (task.section == section) return task.settled.future;
    }
    return Future<void>.value();
  }

  /// Accelerates the preload of [section] when the user navigates to it:
  /// a pending task starts immediately in the foreground, an in-flight task
  /// has its remaining queued commands boosted to foreground, and a finished
  /// task is left alone.
  void prioritizeSection(ClientSection section) {
    if (_disposed || !_started) return;
    for (final task in _ordered) {
      if (task.section != section) continue;
      switch (task.state) {
        case _PreloadState.pending:
          unawaited(_runTask(task, background: false));
        case _PreloadState.running:
          task.token?.background = false;
        case _PreloadState.done:
          break;
      }
      return;
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation += 1;
  }

  List<_PreloadTask> _buildOrder() {
    final current = _currentSection();
    return <_PreloadTask>[
      if (_tasks.containsKey(current))
        _PreloadTask(section: current, action: _tasks[current]!),
      for (final entry in _tasks.entries)
        if (entry.key != current)
          _PreloadTask(section: entry.key, action: entry.value),
    ];
  }

  Future<void> _run(int generation) async {
    for (final task in _ordered) {
      if (!_isCurrent(generation)) return;
      if (task.state != _PreloadState.pending) continue;
      await _runTask(task, background: true);
      if (!_isCurrent(generation)) return;
      await Future<void>.delayed(_interTaskDelay);
    }
  }

  Future<void> _runTask(_PreloadTask task, {required bool background}) async {
    if (task.state != _PreloadState.pending) return;
    task.state = _PreloadState.running;
    final token = RpcPriorityToken(background: background);
    task.token = token;
    try {
      await runWithRpcPriorityToken(token, task.action);
    } on Object catch (_) {
      _onReport(
        ClientLifecycleReport(
          code: 'client_section_preload_failed',
          stepId: task.section.name,
        ),
      );
    } finally {
      task.state = _PreloadState.done;
      task.token = null;
      if (!task.settled.isCompleted) task.settled.complete();
    }
  }

  bool _isCurrent(int generation) => !_disposed && generation == _generation;
}
