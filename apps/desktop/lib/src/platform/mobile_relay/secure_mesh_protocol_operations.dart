import 'package:licoup/src/contracts/generated/secure_mesh.g.dart';
import 'package:licoup/src/platform/mobile_relay/mobile_relay_native_dispatch.dart';
import 'package:licoup/src/platform/secure_mesh/secure_mesh_android_bridge.dart';
import 'package:licoup/src/platform/secure_mesh/secure_mesh_mobile_bridge.dart';

const secureMeshProtocolMobileOnlyErrorCode =
    'secure_mesh_protocol_mobile_only';

final class SecureMeshProtocolOperations {
  const SecureMeshProtocolOperations({
    MobileRelayNativeDispatch dispatch =
        const DefaultMobileRelayNativeDispatch(),
  }) : _dispatch = dispatch;

  final MobileRelayNativeDispatch _dispatch;

  SecureMeshMobileBridge _nativeBridgeForCurrentPlatform({
    required SecureMeshMobileBridge androidBridge,
  }) => _dispatch.bridgeForCurrentPlatform(androidBridge);

  Future<Map<String, dynamic>> _runMobileRelayNative({
    required SecureMeshMobileBridge bridge,
    required String action,
    Map<String, dynamic> params = const {},
    bool authorize = false,
  }) => _dispatch.runMobile(
    bridge: bridge,
    action: action,
    params: params,
    authorize: authorize,
  );

  Future<SecureMeshMlsResponse> executeSecureMeshMlsRequest({
    required SecureMeshMlsRequest request,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _executeSecureMeshMlsRequest(request: request, bridge: bridge);

  Future<SecureMeshKtResponse> executeSecureMeshKtRequest({
    required SecureMeshKtRequest request,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _executeSecureMeshKtRequest(request: request, bridge: bridge);

  Future<SecureMeshMlsResponse> _executeSecureMeshMlsRequest({
    required SecureMeshMlsRequest request,
    required SecureMeshMobileBridge bridge,
  }) async {
    _requireMobileBridge();
    final output = await _runMobileRelayNative(
      bridge: _nativeBridgeForCurrentPlatform(androidBridge: bridge),
      action: request.action.wireName,
      params: request.params,
      authorize: request.action.requiresAuthorization,
    );
    return SecureMeshMlsResponse.fromJson(output);
  }

  Future<SecureMeshKtResponse> _executeSecureMeshKtRequest({
    required SecureMeshKtRequest request,
    required SecureMeshMobileBridge bridge,
  }) async {
    _requireMobileBridge();
    final output = await _runMobileRelayNative(
      bridge: _nativeBridgeForCurrentPlatform(androidBridge: bridge),
      action: request.action.wireName,
      params: request.params,
      authorize: request.action.requiresAuthorization,
    );
    return SecureMeshKtResponse.fromJson(output);
  }

  void _requireMobileBridge() {
    if (!_dispatch.isAndroid && !_dispatch.isIOS) {
      throw UnsupportedError(secureMeshProtocolMobileOnlyErrorCode);
    }
  }
}
