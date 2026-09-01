enum ProtocolConnectionPhase {
  connecting,
  connected,
  disconnected,
  reconnecting,
}

final class ProtocolConnectionState {
  const ProtocolConnectionState({required this.phase, this.failureCode = ''});

  const ProtocolConnectionState.disconnected()
    : phase = ProtocolConnectionPhase.disconnected,
      failureCode = '';

  final ProtocolConnectionPhase phase;
  final String failureCode;

  bool get connected => phase == ProtocolConnectionPhase.connected;
}
