import 'dart:typed_data';

/// The write-only L2 boundary used by event senders.
///
/// Implementations own process lifecycle and stdio buffering. Callers only
/// submit complete generated frames and never await a correlated response.
abstract interface class ProtocolFrameSink {
  void writeFrame(Uint8List frame);
}

final class CallbackProtocolFrameSink implements ProtocolFrameSink {
  const CallbackProtocolFrameSink(this._write);

  final void Function(Uint8List frame) _write;

  @override
  void writeFrame(Uint8List frame) => _write(frame);
}
