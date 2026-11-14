import 'package:licoup/src/platform/native_client/native_cli_ports.dart';

/// Routes catalog payloads through the structured `catalog.*` RPC methods.
///
/// The structured methods are the only catalog contract; there is no argv
/// form of these operations.
final class NativeCatalogActions {
  const NativeCatalogActions({
    required NativeStdioRpcTransport stdioRpcTransport,
  }) : _stdioRpcTransport = stdioRpcTransport;

  static const _allowedOperations = {
    'status',
    'invalidate',
    'refresh',
    'receipt',
    'purge',
    'reconnect',
    'list',
    'observe',
  };

  final NativeStdioRpcTransport _stdioRpcTransport;

  Future<Map<String, dynamic>> execute(
    String operation, {
    Map<String, dynamic> params = const {},
  }) {
    if (!_allowedOperations.contains(operation)) {
      return Future<Map<String, dynamic>>.error(
        const FormatException('catalog_operation_unsupported'),
      );
    }
    return _stdioRpcTransport.executeStructured('catalog.$operation', params);
  }
}
