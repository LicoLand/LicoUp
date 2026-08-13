import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';

const int defaultLlmGatewayPort = 15722;
const String llmGatewayPortSettingsKey = 'llmGatewayPort';

enum LlmGatewayRuntimeState { unknown, running, stopped, unhealthy }

enum LlmGatewayNoticeKind {
  initializationFailed,
  unexpectedExit,
  monitorUnavailable,
  restartFailed,
}

/// Owns the application-wide LLM Gateway lifecycle.
///
/// Production creates exactly one instance. Initialization starts only the
/// local service, polling observes unexpected exits, and explicit starts apply
/// any credential session that the independent authorization flow has loaded.
final class LlmGatewayLifecycleController extends ChangeNotifier {
  LlmGatewayLifecycleController({
    required AgentCommandRunner agentService,
    required Future<Map<String, Object?>> Function() readSettings,
    Duration monitorInterval = const Duration(seconds: 5),
  }) : _agentService = agentService,
       _readSettings = readSettings,
       _monitorInterval = monitorInterval;

  final AgentCommandRunner _agentService;
  final Future<Map<String, Object?>> Function() _readSettings;
  final Duration _monitorInterval;

  Timer? _monitor;
  bool _disposed = false;
  bool _initialized = false;
  bool _busy = false;
  bool _expectedRunning = false;
  bool _observedRunning = false;
  bool _managed = false;
  int _consecutiveMonitorFailures = 0;
  int _port = defaultLlmGatewayPort;
  LlmGatewayRuntimeState _state = LlmGatewayRuntimeState.unknown;
  LlmGatewayNoticeKind? _notice;
  Map<String, dynamic>? _lastReport;

  bool get busy => _busy;
  bool get managed => _managed;
  int get port => _port;
  LlmGatewayRuntimeState get state => _state;
  LlmGatewayNoticeKind? get notice => _notice;
  Map<String, dynamic>? get lastReport => _lastReport;

  Future<void> initialize() async {
    if (_disposed || _initialized) return;
    _initialized = true;
    _port = await _settingsPort();
    _expectedRunning = true;
    _setBusy(true);
    try {
      final report = await _runService('initialize');
      _applyReport(report);
      if (_state != LlmGatewayRuntimeState.running) {
        _notice = LlmGatewayNoticeKind.initializationFailed;
      }
    } catch (_) {
      _state = LlmGatewayRuntimeState.unknown;
      _notice = LlmGatewayNoticeKind.initializationFailed;
    } finally {
      _setBusy(false);
      _startMonitor();
    }
  }

  Future<void> start() => restart();

  Future<void> restart() async {
    if (_disposed || _busy) return;
    _port = await _settingsPort();
    _expectedRunning = true;
    _setBusy(true);
    try {
      if (_state == LlmGatewayRuntimeState.unhealthy && _managed) {
        try {
          await _runService('stop');
        } catch (_) {
          // Start owns the final typed result. A stale unhealthy process may
          // already have exited between the monitor probe and this action.
        }
      }
      final report = await _runService('start');
      _applyReport(report);
      _notice = _state == LlmGatewayRuntimeState.running
          ? null
          : LlmGatewayNoticeKind.restartFailed;
    } catch (_) {
      _notice = LlmGatewayNoticeKind.restartFailed;
    } finally {
      _setBusy(false);
    }
  }

  Future<void> stop() async {
    if (_disposed || _busy) return;
    _expectedRunning = false;
    _notice = null;
    _setBusy(true);
    try {
      _applyReport(await _runService('stop'));
    } finally {
      _setBusy(false);
    }
  }

  /// Public test and UI refresh seam. The periodic monitor calls the same
  /// method, so no second lifecycle implementation exists.
  Future<void> pollNow() async {
    if (_disposed || _busy || !_initialized) return;
    try {
      final report = await _runService('status');
      _consecutiveMonitorFailures = 0;
      _applyReport(report);
      if (_expectedRunning &&
          _observedRunning &&
          _state != LlmGatewayRuntimeState.running) {
        _setNotice(LlmGatewayNoticeKind.unexpectedExit);
      } else if (_state == LlmGatewayRuntimeState.running &&
          (_notice == LlmGatewayNoticeKind.unexpectedExit ||
              _notice == LlmGatewayNoticeKind.monitorUnavailable)) {
        _setNotice(null);
      }
    } catch (_) {
      _consecutiveMonitorFailures += 1;
      if (_expectedRunning &&
          _observedRunning &&
          _consecutiveMonitorFailures >= 2) {
        _setNotice(LlmGatewayNoticeKind.monitorUnavailable);
      }
    }
  }

  Future<Map<String, dynamic>> _runService(String operation) {
    return _agentService.runCli([
      'llm-gateway',
      'service',
      operation,
      '--port',
      '$_port',
    ]);
  }

  void _applyReport(Map<String, dynamic> report) {
    _lastReport = Map.unmodifiable(report);
    _managed = report['managed'] == true;
    _state = switch ('${report['state']}') {
      'running' => LlmGatewayRuntimeState.running,
      'stopped' => LlmGatewayRuntimeState.stopped,
      'unhealthy' => LlmGatewayRuntimeState.unhealthy,
      _ => LlmGatewayRuntimeState.unknown,
    };
    if (_state == LlmGatewayRuntimeState.running) {
      _observedRunning = true;
    }
    final reportedPort = report['port'];
    if (reportedPort is int && _validPort(reportedPort)) {
      _port = reportedPort;
    }
    _notify();
  }

  Future<int> _settingsPort() async {
    try {
      final content = await _readSettings();
      final stored = content[llmGatewayPortSettingsKey];
      final port = stored is int
          ? stored
          : stored is String
          ? int.tryParse(stored)
          : null;
      if (port != null && _validPort(port)) return port;
    } catch (_) {
      // A missing or unreadable preference uses the fixed product default.
    }
    return defaultLlmGatewayPort;
  }

  bool _validPort(int value) => value > 0 && value <= 65535;

  void _startMonitor() {
    if (_disposed || _monitor != null || _monitorInterval <= Duration.zero) {
      return;
    }
    _monitor = Timer.periodic(_monitorInterval, (_) => unawaited(pollNow()));
  }

  void _setBusy(bool value) {
    if (_busy == value) return;
    _busy = value;
    _notify();
  }

  void _setNotice(LlmGatewayNoticeKind? value) {
    if (_notice == value) return;
    _notice = value;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _monitor?.cancel();
    _monitor = null;
    super.dispose();
  }
}
