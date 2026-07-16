import 'package:flutter_client/src/platform/native_client/native_cli_ports.dart';

/// Chooses the persistent transport without exposing transport details to
/// command builders or the public service facade.
class NativeCommandRouter implements NativeCommandExecutor {
  const NativeCommandRouter({
    required NativeCommandExecutor oneShotExecutor,
    required NativeStdioRpcTransport stdioRpcTransport,
    required bool persistentStdioRpcEnabled,
  }) : _oneShotExecutor = oneShotExecutor,
       _stdioRpcTransport = stdioRpcTransport,
       _persistentStdioRpcEnabled = persistentStdioRpcEnabled;

  final NativeCommandExecutor _oneShotExecutor;
  final NativeStdioRpcTransport _stdioRpcTransport;
  final bool _persistentStdioRpcEnabled;

  @override
  Future<Map<String, dynamic>> execute(List<String> arguments) {
    if (_persistentStdioRpcEnabled) {
      return _stdioRpcTransport.execute(arguments);
    }
    return _oneShotExecutor.execute(arguments);
  }
}
