import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/mcp_adapter.dart';
import 'package:licoup/src/platform/native_client/native_mcp_actions.dart';

void main() {
  test(
    'MCP scope and body travel only through bounded private stdin',
    () async {
      final runner = _RecordingPrivateRunner();
      final actions = NativeMcpActions(privateRunner: runner);
      const request = McpHttpTransferRequest(
        direction: McpTransferDirection.request,
        destination: 'https://example.invalid/mcp',
        purpose: 'invoke a selected tool',
        message: <String, dynamic>{
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'tools/call',
        },
      );

      final preview = await actions.previewHttpTransfer(request);
      expect(runner.lastArgs, const [
        'mcp',
        'http',
        'preview',
        '--stdin-json',
        'true',
      ]);
      expect(runner.lastArgs.join(' '), isNot(contains(request.destination)));
      expect(runner.lastArgs.join(' '), isNot(contains('tools/call')));
      final privatePreview =
          jsonDecode(runner.lastStdin) as Map<String, dynamic>;
      expect(privatePreview['requestOrigin'], 'direct-user');
      expect(privatePreview['messageJson'], contains('tools/call'));

      await actions.executeHttpTransfer(preview, confirmed: true);
      final privateExecution =
          jsonDecode(runner.lastStdin) as Map<String, dynamic>;
      expect(privateExecution['planId'], preview.planId);
      expect(privateExecution['approvalDigest'], preview.approvalDigest);
      expect(privateExecution['confirmed'], true);
    },
  );
}

final class _RecordingPrivateRunner implements AgentCommandRunner {
  List<String> lastArgs = const [];
  String lastStdin = '';

  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) async {
    lastArgs = List<String>.from(args);
    lastStdin = stdinText;
    if (args.contains('preview')) {
      final request = jsonDecode(stdinText) as Map<String, dynamic>;
      return <String, dynamic>{
        'ok': true,
        'schemaVersion': 'licoup.mcp-transfer-preview.v1',
        'direction': request['direction'],
        'destination': request['destination'],
        'purpose': request['purpose'],
        'protocolVersion': request['protocolVersion'],
        'requiresDirectUserConfirmation': true,
        'oneShot': true,
        'planId': 'plan-id',
        'approvalDigest': 'a' * 64,
        'messageBytes': 64,
      };
    }
    return <String, dynamic>{
      'ok': true,
      'schemaVersion': 'licoup.mcp-transfer-result.v1',
      'accepted': true,
      'messages': const <Map<String, dynamic>>[],
    };
  }

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) {
    throw UnimplementedError();
  }

  @override
  Stream<Map<String, dynamic>> streamCliJsonLines(List<String> args) {
    throw UnimplementedError();
  }

  @override
  Stream<Map<String, dynamic>> streamCliJsonLinesWithStdin(
    List<String> args,
    String stdinText,
  ) {
    throw UnimplementedError();
  }
}
