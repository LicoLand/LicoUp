import 'package:licoup/src/contracts/generated/conversation_protocol.g.dart';
import 'package:licoup/src/protocol/protocol_frame_sink.dart';

/// Stateless L1 command emitter.
///
/// Serialization is owned by the generated protocol contract. Sending is
/// deliberately fire-and-forget: projected state, not a callback, closes the
/// interaction loop.
final class EventSender {
  const EventSender(this._sink);

  final ProtocolFrameSink _sink;

  void send(ConversationCommand command) {
    _sink.writeFrame(command.encode());
  }
}
