import 'dart:async';

import 'package:licoup/src/application/state/application_signal.dart';

import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/llm_gateway_diagnostics.dart';

const int defaultLlmGatewayPort = 15722;
const String llmGatewayPortSettingsKey = 'llmGatewayPort';

enum LlmGatewayRuntimeState { unknown, running, stopped, unhealthy }

enum LlmGatewayNoticeKind { recovering, recoveryFailed }

/// Owns the application-wide LLM Gateway lifecycle.
///
/// Production creates exactly one instance. Initialization starts the local
/// service, one coalesced monitor observes it, and runtime faults are recovered
/// automatically before a terminal notification is shown.
final class LlmGatewayLifecycleController extends ApplicationStateOwner {
  LlmGatewayLifecycleController({
    required AgentCommandRunner agentService,
    required Future<Map<String, Object?>> Function() readSettings,
    Duration monitorInterval = const Duration(seconds: 5),
    Duration recoveryRetryDelay = const Duration(milliseconds: 500),
    LlmGatewayDiagnosticSink diagnosticSink =
        const NoopLlmGatewayDiagnosticSink(),
  }) : _agentService = agentService,
       _readSettings = readSettings,
       _monitorInterval = monitorInterval,
       _recoveryRetryDelay = recoveryRetryDelay,
       _diagnosticSink = diagnosticSink;

  static const int maxRecoveryAttempts = 3;
  static final RegExp _stableErrorCode = RegExp(r'^[a-z][a-z0-9_-]{0,63}$');

  final AgentCommandRunner _agentService;
  final Future<Map<String, Object?>> Function() _readSettings;
  final Duration _monitorInterval;
  final Duration _recoveryRetryDelay;
  final LlmGatewayDiagnosticSink _diagnosticSink;

  Timer? _monitor;
  Future<void>? _pollFuture;
  Future<void>? _recoveryFuture;
  bool _disposed = false;
  bool _initialized = false;
  bool _busy = false;
  bool _recovering = false;
  bool _expectedRunning = false;
  bool _observedRunning = false;
  bool _managed = false;
  bool _automaticRecoveryExhausted = false;
  int _consecutiveMonitorFailures = 0;
  int _recoveryAttempt = 0;
  int _autoRevealRevision = 0;
  int _port = defaultLlmGatewayPort;
  LlmGatewayRuntimeState _state = LlmGatewayRuntimeState.unknown;
  LlmGatewayNoticeKind? _notice;
  Map<String, dynamic>? _lastReport;

  bool get busy => _busy;
  bool get recovering => _recovering;
  bool get managed => _managed;
  int get port => _port;
  int get recoveryAttempt => _recoveryAttempt;
  int get autoRevealRevision => _autoRevealRevision;
  LlmGatewayRuntimeState get state => _state;
  LlmGatewayNoticeKind? get notice => _notice;
  Map<String, dynamic>? get lastReport => _lastReport;

  Future<void> initialize() async {
    if (_disposed || _initialized) return;
    _initialized = true;
    _port = await _settingsPort();
    _expectedRunning = true;
    _setBusy(true);
    String? initializationFailure;
    try {
      final report = await _runService('initialize');
      _applyReport(report);
      if (_state != LlmGatewayRuntimeState.running) {
        initializationFailure = 'service_${_state.name}';
      }
    } on Object catch (error) {
      _state = LlmGatewayRuntimeState.unknown;
      initializationFailure = _safeErrorCode(error);
    } finally {
      _setBusy(false);
    }

    if (initializationFailure != null) {
      _recordDiagnostic(
        LlmGatewayDiagnosticEvent.initializationFailed,
        errorCode: initializationFailure,
      );
      // Cold-start recovery is intentionally silent: the bell carries a badge
      // but does not pin its panel open over the restored user view.
      await _recover(autoReveal: false);
    }
    _startMonitor();
  }

  Future<void> start() => restart();

  /// Reads the current service state once without claiming that the Gateway
  /// should be running or starting the application-wide recovery monitor.
  Future<void> detect() async {
    if (_disposed || _busy) return;
    _port = await _settingsPort();
    _setBusy(true);
    try {
      _applyReport(await _runService('status'));
    } on Object {
      _state = LlmGatewayRuntimeState.unknown;
      _managed = false;
      _lastReport = null;
      _notify();
      rethrow;
    } finally {
      _setBusy(false);
    }
  }

  /// Starts the service exactly once. Isolated presentation bindings use this
  /// to preserve the explicit card action; the application lifecycle keeps its
  /// recovery-aware [start] path.
  Future<void> startOnce() async {
    if (_disposed || _busy) return;
    _port = await _settingsPort();
    _expectedRunning = true;
    _setBusy(true);
    try {
      _applyReport(await _runService('start'));
    } finally {
      _setBusy(false);
    }
  }

  Future<void> restart() async {
    if (_disposed) return;
    _port = await _settingsPort();
    _expectedRunning = true;
    _automaticRecoveryExhausted = false;
    await _recover(autoReveal: false);
  }

  Future<void> stop() async {
    if (_disposed || _busy) return;
    _expectedRunning = false;
    _clearRecoveryProjection();
    _setBusy(true);
    try {
      _applyReport(await _runService('stop'));
    } finally {
      _setBusy(false);
    }
  }

  /// Public test and UI refresh seam. Periodic calls share one in-flight
  /// request so a slow native command cannot build an overlapping poll queue.
  Future<void> pollNow() {
    final active = _pollFuture;
    if (active != null) return active;
    late final Future<void> poll;
    poll = _pollOnce().whenComplete(() {
      if (identical(_pollFuture, poll)) _pollFuture = null;
    });
    _pollFuture = poll;
    return poll;
  }

  Future<void> _pollOnce() async {
    if (_disposed || _busy || !_initialized) return;
    try {
      final report = await _runService('status');
      _consecutiveMonitorFailures = 0;
      _applyReport(report);
      if (_expectedRunning &&
          _observedRunning &&
          !_automaticRecoveryExhausted &&
          _state != LlmGatewayRuntimeState.running) {
        await _recover(autoReveal: true);
      } else if (_state == LlmGatewayRuntimeState.running &&
          _notice == LlmGatewayNoticeKind.recoveryFailed) {
        _clearRecoveryProjection();
      }
    } on Object catch (error) {
      _consecutiveMonitorFailures += 1;
      if (_expectedRunning &&
          _observedRunning &&
          !_automaticRecoveryExhausted &&
          _consecutiveMonitorFailures >= 2) {
        _consecutiveMonitorFailures = 0;
        _recordDiagnostic(
          LlmGatewayDiagnosticEvent.monitorCheckFailed,
          errorCode: _safeErrorCode(error),
        );
        // Native start is health-aware and returns the running process without
        // replacing it, so this also repairs monitor transport false alarms
        // without disrupting a healthy Gateway.
        await _recover(autoReveal: true);
      }
    }
  }

  Future<void> _recover({required bool autoReveal}) {
    final active = _recoveryFuture;
    if (active != null) return active;
    if (_disposed || !_expectedRunning) return Future<void>.value();
    late final Future<void> recovery;
    recovery = _runRecovery(autoReveal: autoReveal).whenComplete(() {
      if (identical(_recoveryFuture, recovery)) _recoveryFuture = null;
    });
    _recoveryFuture = recovery;
    return recovery;
  }

  Future<void> _runRecovery({required bool autoReveal}) async {
    _automaticRecoveryExhausted = false;
    _recovering = true;
    _recoveryAttempt = 0;
    _setNotice(LlmGatewayNoticeKind.recovering, autoReveal: autoReveal);
    _setBusy(true);
    var lastErrorCode = 'service_not_running';
    for (var attempt = 1; attempt <= maxRecoveryAttempts; attempt += 1) {
      if (_disposed || !_expectedRunning) break;
      if (attempt > 1 && _recoveryRetryDelay > Duration.zero) {
        await Future<void>.delayed(_recoveryRetryDelay);
        if (_disposed || !_expectedRunning) break;
      }
      _recoveryAttempt = attempt;
      _notify();
      try {
        if (_state == LlmGatewayRuntimeState.unhealthy && _managed) {
          try {
            await _runService('stop');
          } on Object {
            // Start owns the final typed result. A stale unhealthy process may
            // already have exited between the monitor probe and this action.
          }
        }
        final report = await _runService('start');
        _applyReport(report);
        if (_state == LlmGatewayRuntimeState.running) {
          _clearRecoveryProjection();
          _setBusy(false);
          return;
        }
        lastErrorCode = 'service_${_state.name}';
      } on Object catch (error) {
        lastErrorCode = _safeErrorCode(error);
      }
      _recordDiagnostic(
        LlmGatewayDiagnosticEvent.recoveryAttemptFailed,
        errorCode: lastErrorCode,
        attempt: attempt,
      );
    }

    if (_disposed || !_expectedRunning) {
      _recovering = false;
      _recoveryAttempt = 0;
      _notice = null;
      _busy = false;
      return;
    }
    _automaticRecoveryExhausted = true;
    _recovering = false;
    _recoveryAttempt = maxRecoveryAttempts;
    _setNotice(LlmGatewayNoticeKind.recoveryFailed);
    _setBusy(false);
    _recordDiagnostic(
      LlmGatewayDiagnosticEvent.recoveryExhausted,
      errorCode: lastErrorCode,
      attempt: maxRecoveryAttempts,
    );
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
    } on Object {
      // A missing or unreadable preference uses the fixed product default.
    }
    return defaultLlmGatewayPort;
  }

  bool _validPort(int value) => value > 0 && value <= 65535;

  String _safeErrorCode(Object error) {
    try {
      final candidate = (error as dynamic).code;
      if (candidate is String && _stableErrorCode.hasMatch(candidate)) {
        return candidate;
      }
    } on Object {
      // Unknown exceptions deliberately collapse to one non-sensitive code.
    }
    return 'command_failed';
  }

  void _recordDiagnostic(
    LlmGatewayDiagnosticEvent event, {
    required String errorCode,
    int attempt = 0,
  }) {
    unawaited(
      _diagnosticSink
          .record(
            LlmGatewayDiagnosticRecord(
              event: event,
              createdAt: DateTime.now(),
              runtimeState: _state.name,
              errorCode: errorCode,
              attempt: attempt,
            ),
          )
          .catchError((_) {}),
    );
  }

  void _clearRecoveryProjection() {
    _automaticRecoveryExhausted = false;
    _recovering = false;
    _recoveryAttempt = 0;
    _setNotice(null);
  }

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

  void _setNotice(LlmGatewayNoticeKind? value, {bool autoReveal = false}) {
    final changed = _notice != value;
    _notice = value;
    if (autoReveal) _autoRevealRevision += 1;
    if (changed || autoReveal) _notify();
  }

  void _notify() {
    if (!_disposed) publishChange();
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
