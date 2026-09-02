import 'dart:convert';
import 'dart:typed_data';

import 'package:licoup/src/contracts/generated/client_error.g.dart';
import 'package:licoup/src/contracts/generated/conversation_protocol.g.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/protocol.dart';

// ClientError decoding preserves code, stage, component, retryable, recovery,
// and presentationArgs as one generated value. Envelope framing and delta
// sequencing are done by the generated ConversationDeltaDecoder; this file
// only adds the stream-specific session/turn identity rules on top.
class StdioRpcProtocolViolation implements Exception {
  const StdioRpcProtocolViolation();
}

class StdioRpcCommandReply {
  const StdioRpcCommandReply.success(this.result) : error = null;
  const StdioRpcCommandReply.failure(this.error) : result = null;

  final Map<String, dynamic>? result;
  final ClientError? error;
}

String? stdioRpcEnvelopeRequestId(Uint8List bytes) {
  try {
    final decoded = _decodeEnvelope(bytes);
    final requestId = decoded['id'];
    return requestId is String && requestId.isNotEmpty ? requestId : null;
  } on StdioRpcProtocolViolation {
    return null;
  }
}

StdioRpcCommandReply decodeStdioRpcCommandReply(
  Uint8List bytes, {
  required String requestId,
  required String workflowId,
}) {
  final decoded = _decodeEnvelope(bytes);
  if (decoded['protocol'] != stdioRpcProtocol ||
      decoded['id'] != requestId ||
      decoded['workflowId'] != workflowId ||
      decoded['ok'] is! bool) {
    throw const StdioRpcProtocolViolation();
  }
  if (decoded['ok'] == true) {
    final result = decoded['result'];
    if (result is! Map<String, dynamic>) {
      throw const StdioRpcProtocolViolation();
    }
    return StdioRpcCommandReply.success(result);
  }
  return StdioRpcCommandReply.failure(_clientError(decoded['error']));
}

bool isStdioRpcShutdownAcknowledged(
  Uint8List bytes, {
  required String requestId,
  required String workflowId,
}) {
  try {
    final decoded = _decodeEnvelope(bytes);
    return decoded['protocol'] == stdioRpcProtocol &&
        decoded['id'] == requestId &&
        decoded['workflowId'] == workflowId &&
        decoded['ok'] == true;
  } on Object {
    return false;
  }
}

sealed class StdioRpcConversationFrame {
  const StdioRpcConversationFrame();
}

final class StdioRpcConversationEvent extends StdioRpcConversationFrame {
  const StdioRpcConversationEvent(this.event);

  final Map<String, dynamic> event;
}

final class StdioRpcConversationTerminal extends StdioRpcConversationFrame {
  const StdioRpcConversationTerminal.success(this.result) : error = null;
  const StdioRpcConversationTerminal.failure(this.error) : result = null;

  final Map<String, dynamic>? result;
  final ClientError? error;
}

class StdioRpcConversationDecoder {
  StdioRpcConversationDecoder({
    required this.requestId,
    required this.workflowId,
  }) : _deltaDecoder = ConversationDeltaDecoder(
         requestId: requestId,
         workflowId: workflowId,
       );

  final String requestId;
  final String workflowId;
  final ConversationDeltaDecoder _deltaDecoder;

  StdioRpcConversationFrame decode(Uint8List bytes) {
    late ConversationDelta delta;
    try {
      delta = _deltaDecoder.decode(bytes);
    } on FormatException {
      throw const StdioRpcProtocolViolation();
    }
    if (delta is ConversationDeltaEvent) {
      final event = delta.event;
      final persistent =
          (event['turnHandle'] ?? '').toString().trim().isNotEmpty &&
          (event['conversationId'] ?? '').toString().trim().isNotEmpty &&
          event['cursor'] is int &&
          (event['cursor'] as int) > 0;
      if (!persistent &&
          ((event['sessionId'] ?? '').toString().trim().isEmpty ||
              (event['turnId'] ?? '').toString().trim().isEmpty)) {
        throw const StdioRpcProtocolViolation();
      }
      return StdioRpcConversationEvent(Map<String, dynamic>.from(event));
    }
    final terminal = delta as ConversationDeltaTerminal;
    if (terminal.ok) {
      return StdioRpcConversationTerminal.success(terminal.result!);
    }
    return StdioRpcConversationTerminal.failure(_clientError(terminal.error));
  }
}

Map<String, dynamic> _decodeEnvelope(Uint8List bytes) {
  try {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
  } on Object {
    // The public transport maps every malformed envelope to one redacted code.
  }
  throw const StdioRpcProtocolViolation();
}

ClientError _clientError(Object? value) {
  if (value is! Map) {
    throw const StdioRpcProtocolViolation();
  }
  return ClientError.fromJson(Map<String, Object?>.from(value));
}
