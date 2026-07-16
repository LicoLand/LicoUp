enum McpTransferDirection {
  request('request'),
  response('response');

  const McpTransferDirection(this.wireName);

  final String wireName;
}

final class McpHttpTransferRequest {
  const McpHttpTransferRequest({
    required this.direction,
    required this.destination,
    required this.purpose,
    required this.message,
    this.protocolVersion = '2025-11-25',
    this.sessionId = '',
  });

  final McpTransferDirection direction;
  final String destination;
  final String purpose;
  final Map<String, dynamic> message;
  final String protocolVersion;
  final String sessionId;
}

final class McpHttpTransferPreview {
  const McpHttpTransferPreview({
    required this.request,
    required this.planId,
    required this.approvalDigest,
    required this.messageBytes,
  });

  factory McpHttpTransferPreview.fromJson(
    Map<String, dynamic> json, {
    required McpHttpTransferRequest request,
  }) {
    final planId = json['planId'];
    final digest = json['approvalDigest'];
    final messageBytes = json['messageBytes'];
    if (json['ok'] != true ||
        json['schemaVersion'] != 'licoarc.mcp-transfer-preview.v1' ||
        json['direction'] != request.direction.wireName ||
        json['destination'] != request.destination ||
        json['purpose'] != request.purpose ||
        json['protocolVersion'] != request.protocolVersion ||
        json['requiresDirectUserConfirmation'] != true ||
        json['oneShot'] != true ||
        planId is! String ||
        planId.isEmpty ||
        digest is! String ||
        !_isSha256(digest) ||
        messageBytes is! int ||
        messageBytes <= 0) {
      throw const FormatException('mcp_transfer_preview_invalid');
    }
    return McpHttpTransferPreview(
      request: request,
      planId: planId,
      approvalDigest: digest,
      messageBytes: messageBytes,
    );
  }

  final McpHttpTransferRequest request;
  final String planId;
  final String approvalDigest;
  final int messageBytes;
}

final class McpHttpTransferResult {
  const McpHttpTransferResult({
    required this.accepted,
    required this.messages,
    this.sessionId = '',
  });

  factory McpHttpTransferResult.fromJson(Map<String, dynamic> json) {
    if (json['ok'] != true ||
        json['schemaVersion'] != 'licoarc.mcp-transfer-result.v1' ||
        json['accepted'] != true) {
      throw const FormatException('mcp_transfer_result_invalid');
    }
    final session = json['sessionId'];
    final rawMessages = json['messages'];
    if (session != null && session is! String) {
      throw const FormatException('mcp_transfer_result_invalid');
    }
    final messages = rawMessages == null
        ? const <Map<String, dynamic>>[]
        : rawMessages is List
        ? rawMessages
              .whereType<Map>()
              .map((value) => Map<String, dynamic>.from(value))
              .toList(growable: false)
        : throw const FormatException('mcp_transfer_result_invalid');
    if (rawMessages is List && messages.length != rawMessages.length) {
      throw const FormatException('mcp_transfer_result_invalid');
    }
    return McpHttpTransferResult(
      accepted: true,
      sessionId: session as String? ?? '',
      messages: messages,
    );
  }

  final bool accepted;

  /// Opaque MCP session handle. Callers must keep this value in memory or a
  /// platform-secure store and must never include it in logs or diagnostics.
  final String sessionId;
  final List<Map<String, dynamic>> messages;
}

abstract class McpAdapterGateway {
  Future<McpHttpTransferPreview> previewHttpTransfer(
    McpHttpTransferRequest request,
  );

  Future<McpHttpTransferResult> executeHttpTransfer(
    McpHttpTransferPreview preview, {
    required bool confirmed,
  });
}

bool _isSha256(String value) {
  return value.length == 64 && RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(value);
}
