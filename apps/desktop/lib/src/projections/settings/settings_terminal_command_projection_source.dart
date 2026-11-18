import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/features/settings/controller/terminal_command_controller.dart';
import 'package:licoup/src/platform/native_client/terminal_command_port.dart';
import 'package:licoup/src/presentation/settings/settings_projection.dart';
import 'package:licoup/src/projections/close_broadcast_controller.dart';

final class SettingsTerminalCommandProjectionSource
    implements ProjectionSource<SettingsTerminalCommandProjection> {
  SettingsTerminalCommandProjectionSource({
    TerminalCommandController? controller,
  }) : _controller = controller ?? TerminalCommandController();

  final TerminalCommandController _controller;
  final StreamController<ProjectionUpdate<SettingsTerminalCommandProjection>>
  _changes =
      StreamController<
        ProjectionUpdate<SettingsTerminalCommandProjection>
      >.broadcast(sync: true);
  SettingsTerminalCommandProjection _current =
      const SettingsTerminalCommandProjection.loading();
  bool _disposed = false;

  @override
  SettingsTerminalCommandProjection get current => _current;

  @override
  Stream<ProjectionUpdate<SettingsTerminalCommandProjection>> get changes =>
      _changes.stream;

  Future<void> refresh({TraceContext? trace}) async {
    if (_disposed) return;
    if (!_controller.supported) {
      _publish(
        const SettingsTerminalCommandProjection(
          phase: TerminalCommandPhase.unsupported,
          supported: false,
        ),
        trace,
      );
      return;
    }
    try {
      final inspection = await _controller.inspect();
      _publish(
        _current.copyWith(
          phase: TerminalCommandPhase.ready,
          supported: true,
          status: _statusOf(inspection.status),
          occupiedPath: inspection.occupiedPath,
          clearOccupiedPath: inspection.occupiedPath == null,
        ),
        trace,
      );
    } on Object {
      _publish(
        _current.copyWith(
          phase: TerminalCommandPhase.ready,
          supported: true,
          result: TerminalCommandResult.failed,
        ),
        trace,
      );
    }
  }

  Future<void> install({TraceContext? trace}) =>
      _apply(() => _controller.install(), trace);

  Future<void> uninstall({TraceContext? trace}) =>
      _apply(() => _controller.uninstall(), trace);

  bool get _applyingOrDisposed =>
      _disposed || _current.phase == TerminalCommandPhase.applying;

  Future<void> _apply(
    Future<(TerminalCommandActionResult, String?)> Function() action,
    TraceContext? trace,
  ) async {
    if (_applyingOrDisposed) return;
    _publish(_current.copyWith(phase: TerminalCommandPhase.applying), trace);
    final (result, occupiedPath) = await action();
    _publish(
      _current.copyWith(
        phase: TerminalCommandPhase.ready,
        result: _resultOf(result),
        occupiedPath: occupiedPath,
      ),
      trace,
    );
    await refresh(trace: trace);
  }

  static TerminalCommandLinkStatus _statusOf(TerminalCommandStatus status) =>
      switch (status) {
        TerminalCommandStatus.notInstalled =>
          TerminalCommandLinkStatus.notInstalled,
        TerminalCommandStatus.installed => TerminalCommandLinkStatus.installed,
        TerminalCommandStatus.stale => TerminalCommandLinkStatus.stale,
        TerminalCommandStatus.occupied => TerminalCommandLinkStatus.occupied,
      };

  static TerminalCommandResult _resultOf(
    TerminalCommandActionResult result,
  ) => switch (result) {
    TerminalCommandActionResult.installed => TerminalCommandResult.installed,
    TerminalCommandActionResult.uninstalled =>
      TerminalCommandResult.uninstalled,
    TerminalCommandActionResult.occupied => TerminalCommandResult.occupied,
    TerminalCommandActionResult.notInstalled =>
      TerminalCommandResult.notInstalled,
    TerminalCommandActionResult.cancelled => TerminalCommandResult.cancelled,
    _ => TerminalCommandResult.failed,
  };

  void _publish(SettingsTerminalCommandProjection next, TraceContext? trace) {
    if (_disposed || next == _current) return;
    _current = next;
    _changes.add(ProjectionUpdate(next, trace: trace));
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await closeBroadcastController(_changes);
  }
}
