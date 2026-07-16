import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_client/src/platform/native_client/agent_service_stdio_rpc/protocol.dart';

class StdioRpcProtocolViolation implements Exception {
  const StdioRpcProtocolViolation();
}

class StdioRpcCommandReply {
  const StdioRpcCommandReply.success(this.result) : errorCode = null;
  const StdioRpcCommandReply.failure(this.errorCode) : result = null;

  final Map<String, dynamic>? result;
  final String? errorCode;
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
  return StdioRpcCommandReply.failure(_errorCode(decoded['error']));
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
  const StdioRpcConversationTerminal.success(this.result) : errorCode = null;
  const StdioRpcConversationTerminal.failure(this.errorCode) : result = null;

  final Map<String, dynamic>? result;
  final String? errorCode;
}

class StdioRpcConversationDecoder {
  StdioRpcConversationDecoder({
    required this.requestId,
    required this.workflowId,
  });

  final String requestId;
  final String workflowId;
  var _expectedSequence = 1;
  var _terminalSeen = false;

  StdioRpcConversationFrame decode(Uint8List bytes) {
    final decoded = _decodeEnvelope(bytes);
    if (_terminalSeen ||
        decoded['protocol'] != stdioRpcProtocol ||
        decoded['id'] != requestId ||
        decoded['workflowId'] != workflowId ||
        decoded['sequence'] != _expectedSequence) {
      throw const StdioRpcProtocolViolation();
    }
    _expectedSequence += 1;
    final kind = decoded['kind'];
    if (kind == 'event') {
      final event = decoded['event'];
      if (event is! Map<String, dynamic> ||
          (event['event'] ?? '').toString().trim().isEmpty ||
          (event['sessionId'] ?? '').toString().trim().isEmpty ||
          (event['turnId'] ?? '').toString().trim().isEmpty) {
        throw const StdioRpcProtocolViolation();
      }
      return StdioRpcConversationEvent(Map<String, dynamic>.from(event));
    }
    if (kind != 'terminal' || decoded['ok'] is! bool) {
      throw const StdioRpcProtocolViolation();
    }
    _terminalSeen = true;
    if (decoded['ok'] == true) {
      final result = decoded['result'];
      if (result is! Map<String, dynamic>) {
        throw const StdioRpcProtocolViolation();
      }
      return StdioRpcConversationTerminal.success(result);
    }
    return StdioRpcConversationTerminal.failure(_errorCode(decoded['error']));
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

String _errorCode(Object? error) {
  final rawCode = error is Map<String, dynamic> ? error['code'] : null;
  return rawCode is String && validStdioRpcErrorCode(rawCode)
      ? rawCode
      : 'command_failed';
}
