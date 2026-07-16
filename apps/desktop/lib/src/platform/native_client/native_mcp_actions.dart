import 'dart:convert';

import 'package:flutter_client/src/contracts/agent_command_runner.dart';
import 'package:flutter_client/src/contracts/mcp_adapter.dart';

/// Private-stdin command adapter for MCP previews and exact one-shot transfer.
/// No endpoint, purpose, session handle, or JSON-RPC body is placed in process
/// arguments.
final class NativeMcpActions implements McpAdapterGateway {
  const NativeMcpActions({required AgentCommandRunner privateRunner})
    : _privateRunner = privateRunner;

  final AgentCommandRunner _privateRunner;

  @override
  Future<McpHttpTransferPreview> previewHttpTransfer(
    McpHttpTransferRequest request,
  ) async {
    final output = await _privateRunner.runCliWithStdin(const [
      'mcp',
      'http',
      'preview',
      '--stdin-json',
      'true',
    ], jsonEncode(_requestJson(request)));
    return McpHttpTransferPreview.fromJson(output, request: request);
  }

  @override
  Future<McpHttpTransferResult> executeHttpTransfer(
    McpHttpTransferPreview preview, {
    required bool confirmed,
  }) async {
    if (!confirmed) {
      throw const FormatException('mcp_transfer_confirmation_required');
    }
    final request = <String, dynamic>{
      ..._requestJson(preview.request),
      'planId': preview.planId,
      'approvalDigest': preview.approvalDigest,
      'confirmed': true,
    };
    final output = await _privateRunner.runCliWithStdin(const [
      'mcp',
      'http',
      'execute',
      '--stdin-json',
      'true',
    ], jsonEncode(request));
    return McpHttpTransferResult.fromJson(output);
  }

  Map<String, dynamic> _requestJson(McpHttpTransferRequest request) {
    return <String, dynamic>{
      'direction': request.direction.wireName,
      'destination': request.destination,
      'purpose': request.purpose,
      'protocolVersion': request.protocolVersion,
      'messageJson': jsonEncode(request.message),
      'requestOrigin': 'direct-user',
      if (request.sessionId.isNotEmpty) 'sessionId': request.sessionId,
    };
  }
}
