import 'package:licoup/src/application/state/application_signal.dart';

import 'package:licoup/src/contracts/mcp_adapter.dart';

/// Owns one explicit preview/confirm transfer closure. Construction and state
/// changes never issue MCP requests automatically.
final class McpTransferController extends ApplicationStateOwner {
  McpTransferController({required McpAdapterGateway gateway})
    : _gateway = gateway;

  final McpAdapterGateway _gateway;

  McpHttpTransferPreview? _preview;
  McpHttpTransferResult? _result;
  bool _busy = false;
  String _errorCode = '';

  McpHttpTransferPreview? get preview => _preview;
  McpHttpTransferResult? get result => _result;
  bool get busy => _busy;
  String get errorCode => _errorCode;

  Future<bool> createPreview(McpHttpTransferRequest request) async {
    if (_busy) return false;
    _busy = true;
    _errorCode = '';
    _result = null;
    publishChange();
    try {
      _preview = await _gateway.previewHttpTransfer(request);
      return true;
    } on Object {
      _preview = null;
      _errorCode = 'mcp_transfer_preview_failed';
      return false;
    } finally {
      _busy = false;
      publishChange();
    }
  }

  Future<bool> executePreview({required bool confirmed}) async {
    final preview = _preview;
    if (preview == null) {
      _errorCode = 'mcp_transfer_preview_required';
      publishChange();
      return false;
    }
    if (!confirmed) {
      _errorCode = 'mcp_transfer_confirmation_required';
      publishChange();
      return false;
    }
    if (_busy) return false;
    _busy = true;
    _errorCode = '';
    publishChange();
    try {
      _result = await _gateway.executeHttpTransfer(preview, confirmed: true);
      _preview = null;
      return true;
    } on Object {
      // The native plan is one-shot and may already have been consumed before
      // transport failure. A fresh preview is required for every retry.
      _preview = null;
      _result = null;
      _errorCode = 'mcp_transfer_execute_failed';
      return false;
    } finally {
      _busy = false;
      publishChange();
    }
  }

  void discardPreview() {
    if (_busy) return;
    _preview = null;
    _result = null;
    _errorCode = '';
    publishChange();
  }
}
