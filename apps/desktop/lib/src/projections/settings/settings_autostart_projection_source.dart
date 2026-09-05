import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/presentation/settings/settings_intent.dart';
import 'package:licoup/src/presentation/settings/settings_projection.dart';
import 'package:licoup/src/projections/close_broadcast_controller.dart';

final class SettingsAutostartProjectionSource
    implements ProjectionSource<SettingsAutostartProjection> {
  SettingsAutostartProjectionSource({
    required AgentCommandRunner runner,
    required int Function() readGatewayPort,
  }) : _runner = runner,
       _readGatewayPort = readGatewayPort;

  final AgentCommandRunner _runner;
  final int Function() _readGatewayPort;
  final StreamController<ProjectionUpdate<SettingsAutostartProjection>>
  _changes =
      StreamController<ProjectionUpdate<SettingsAutostartProjection>>.broadcast(
        sync: true,
      );
  SettingsAutostartProjection _current =
      const SettingsAutostartProjection.loading();
  bool _disposed = false;

  @override
  SettingsAutostartProjection get current => _current;

  @override
  Stream<ProjectionUpdate<SettingsAutostartProjection>> get changes =>
      _changes.stream;

  Future<void> refresh({TraceContext? trace}) => _load(
    trace: trace,
    successResult: SettingsAutostartResult.none,
    failureResult: SettingsAutostartResult.loadFailed,
    showLoading: true,
  );

  Future<void> set({
    required SettingsAutostartComponent component,
    required bool enabled,
    required bool? silent,
    TraceContext? trace,
  }) async {
    if (_disposed ||
        !_current.supported ||
        _current.phase == SettingsAutostartPhase.applying) {
      return;
    }
    _publish(
      _current.copyWith(
        phase: SettingsAutostartPhase.applying,
        result: SettingsAutostartResult.none,
      ),
      trace,
    );
    final arguments = <String>[
      'autostart',
      'set',
      '--component',
      component.name,
      '--enabled',
      enabled ? 'true' : 'false',
    ];
    if (component == SettingsAutostartComponent.desktop && silent != null) {
      arguments.addAll(['--silent', silent ? 'true' : 'false']);
    }
    if (component == SettingsAutostartComponent.gateway) {
      arguments.addAll(['--port', '${_readGatewayPort()}']);
    }
    try {
      final payload = await _runner.runCli(arguments);
      if (_disposed) return;
      _publish(
        _fromPayload(payload, result: SettingsAutostartResult.saved),
        trace,
      );
    } catch (_) {
      await _load(
        trace: trace,
        successResult: SettingsAutostartResult.saveFailed,
        failureResult: SettingsAutostartResult.saveFailed,
        showLoading: false,
      );
    }
  }

  Future<void> _load({
    required TraceContext? trace,
    required SettingsAutostartResult successResult,
    required SettingsAutostartResult failureResult,
    required bool showLoading,
  }) async {
    if (_disposed) return;
    if (showLoading) {
      _publish(
        _current.copyWith(
          phase: SettingsAutostartPhase.loading,
          result: SettingsAutostartResult.none,
        ),
        trace,
      );
    }
    try {
      final payload = await _runner.runCli(const ['autostart', 'status']);
      if (_disposed) return;
      _publish(_fromPayload(payload, result: successResult), trace);
    } catch (_) {
      _publish(
        _current.copyWith(
          phase: SettingsAutostartPhase.failed,
          supported: false,
          result: failureResult,
        ),
        trace,
      );
    }
  }

  SettingsAutostartProjection _fromPayload(
    Map<String, dynamic> payload, {
    required SettingsAutostartResult result,
  }) {
    final desktop = payload['desktop'];
    final gateway = payload['gateway'];
    final mcp = payload['mcp'];
    final supported = payload['supported'] == true;
    return SettingsAutostartProjection(
      phase: supported
          ? SettingsAutostartPhase.ready
          : SettingsAutostartPhase.unsupported,
      supported: supported,
      desktopEnabled: desktop is Map && desktop['enabled'] == true,
      desktopSilent: desktop is Map && desktop['silent'] == true,
      gatewayEnabled: gateway is Map && gateway['enabled'] == true,
      mcpEnabled: mcp is Map && mcp['enabled'] == true,
      result: result,
    );
  }

  void _publish(SettingsAutostartProjection next, TraceContext? trace) {
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
