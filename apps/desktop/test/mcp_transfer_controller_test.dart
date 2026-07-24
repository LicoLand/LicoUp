import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/features/mcp/controller/mcp_transfer_controller.dart';
import 'package:licoup/src/contracts/mcp_adapter.dart';

void main() {
  test(
    'transfer requires preview then direct confirmation exactly once',
    () async {
      final gateway = _FakeMcpGateway();
      final controller = McpTransferController(gateway: gateway);
      const request = McpHttpTransferRequest(
        direction: McpTransferDirection.request,
        destination: 'https://example.invalid/mcp',
        purpose: 'invoke a selected tool',
        message: <String, dynamic>{
          'jsonrpc': '2.0',
          'id': 'request-1',
          'method': 'tools/call',
        },
      );

      expect(await controller.executePreview(confirmed: true), isFalse);
      expect(controller.errorCode, 'mcp_transfer_preview_required');
      expect(await controller.createPreview(request), isTrue);
      expect(await controller.executePreview(confirmed: false), isFalse);
      expect(gateway.executeCount, 0);
      expect(await controller.executePreview(confirmed: true), isTrue);
      expect(gateway.executeCount, 1);
      expect(controller.preview, isNull);
      expect(await controller.executePreview(confirmed: true), isFalse);
      expect(gateway.executeCount, 1);
    },
  );
}

final class _FakeMcpGateway implements McpAdapterGateway {
  var executeCount = 0;

  @override
  Future<McpHttpTransferPreview> previewHttpTransfer(
    McpHttpTransferRequest request,
  ) async {
    return McpHttpTransferPreview(
      request: request,
      planId: 'preview-plan',
      approvalDigest: 'a' * 64,
      messageBytes: 128,
    );
  }

  @override
  Future<McpHttpTransferResult> executeHttpTransfer(
    McpHttpTransferPreview preview, {
    required bool confirmed,
  }) async {
    executeCount += 1;
    return const McpHttpTransferResult(accepted: true, messages: []);
  }
}
