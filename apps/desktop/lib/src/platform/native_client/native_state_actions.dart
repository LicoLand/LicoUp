import 'package:licoup/src/contracts/generated/client_state.g.dart';
import 'package:licoup/src/platform/native_client/native_cli_ports.dart';

/// Typed client-state gateway over the private structured RPC transport.
final class NativeStateActions {
  const NativeStateActions({required NativeStdioRpcTransport stdioRpcTransport})
    : _stdioRpcTransport = stdioRpcTransport;

  final NativeStdioRpcTransport _stdioRpcTransport;

  Future<ClientStateGetResult> get(ClientStateGetRequest request) async {
    try {
      final result = await _stdioRpcTransport.executeStructured(
        'state.get',
        request.toJson(),
      );
      return ClientStateGetResult.fromJson(result);
    } on LicoClientRpcException catch (error) {
      throw _stateFailure(error);
    }
  }

  Future<ClientStateSetResult> set(ClientStateSetRequest request) async {
    try {
      final result = await _stdioRpcTransport.executeStructured(
        'state.set',
        request.toJson(),
      );
      return ClientStateSetResult.fromJson(result);
    } on LicoClientRpcException catch (error) {
      throw _stateFailure(error);
    }
  }

  ClientStateFailure _stateFailure(LicoClientRpcException error) {
    final failure = ClientStateFailure.fromJson(<String, Object?>{
      'code': error.code,
    });
    if (failure.code == ClientStateFailureCode.unknown) {
      throw error;
    }
    return failure;
  }
}
