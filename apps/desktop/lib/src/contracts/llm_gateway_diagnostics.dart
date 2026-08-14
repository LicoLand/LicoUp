enum LlmGatewayDiagnosticEvent {
  initializationFailed('initialization_failed'),
  monitorCheckFailed('monitor_check_failed'),
  recoveryAttemptFailed('recovery_attempt_failed'),
  recoveryExhausted('recovery_exhausted');

  const LlmGatewayDiagnosticEvent(this.wireName);

  final String wireName;
}

/// A deliberately narrow Gateway diagnostic record.
///
/// It carries only stable control-flow codes. Command output, exception text,
/// process identifiers, paths, prompts, and credentials are never accepted.
final class LlmGatewayDiagnosticRecord {
  const LlmGatewayDiagnosticRecord({
    required this.event,
    required this.createdAt,
    required this.runtimeState,
    required this.errorCode,
    this.attempt = 0,
  });

  final LlmGatewayDiagnosticEvent event;
  final DateTime createdAt;
  final String runtimeState;
  final String errorCode;
  final int attempt;
}

abstract interface class LlmGatewayDiagnosticSink {
  Future<void> record(LlmGatewayDiagnosticRecord record);
}

final class NoopLlmGatewayDiagnosticSink implements LlmGatewayDiagnosticSink {
  const NoopLlmGatewayDiagnosticSink();

  @override
  Future<void> record(LlmGatewayDiagnosticRecord record) async {}
}
