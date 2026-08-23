import 'package:licoup/src/contracts/generated/conversation_protocol.g.dart';

// Method classification is schema-derived: every wire name and every lane,
// stream, control, and action-set decision below comes from the generated
// conversation protocol registry. There is no hand-written method-name table
// left on the Dart side.

bool validStdioRpcStructuredMethod(String method) =>
    conversationProtocolMethodIsStructured(method);

bool stdioRpcMethodUsesConversationLane(
  String method, [
  Map<String, dynamic>? params,
]) => conversationProtocolMethodUsesConversationLane(method, params);

bool stdioRpcMethodIsUnboundedClientTurn(
  String method,
  Map<String, dynamic> params,
) => conversationProtocolMethodIsUnbounded(method, params);

bool stdioRpcMethodIsInFlightControl(String method) =>
    conversationProtocolMethodIsInFlightControl(method);

bool stdioRpcMethodIsStream(String method) =>
    conversationProtocolMethodIsStream(method);
