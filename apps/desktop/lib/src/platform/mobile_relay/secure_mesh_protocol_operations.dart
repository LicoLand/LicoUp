import 'dart:convert';

import 'package:flutter_client/src/contracts/agent_command_runner.dart';
import 'package:flutter_client/src/contracts/generated/secure_mesh.g.dart';
import 'package:flutter_client/src/platform/mobile_relay/mobile_relay_native_dispatch.dart';
import 'package:flutter_client/src/platform/secure_mesh/secure_mesh_android_bridge.dart';
import 'package:flutter_client/src/platform/secure_mesh/secure_mesh_mobile_bridge.dart';

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
    required AgentCommandRunner agentService,
    required SecureMeshKtRequest request,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _executeSecureMeshKtRequest(
    agentService: agentService,
    request: request,
    bridge: bridge,
  );

  Future<SecureMeshMlsResponse> _executeSecureMeshMlsRequest({
    required SecureMeshMlsRequest request,
    required SecureMeshMobileBridge bridge,
  }) async {
    if (!_dispatch.isAndroid && !_dispatch.isIOS) {
      throw UnsupportedError(
        'Secure Mesh MLS native actions currently require a mobile native bridge.',
      );
    }
    final output = await _runMobileRelayNative(
      bridge: _nativeBridgeForCurrentPlatform(androidBridge: bridge),
      action: request.action.wireName,
      params: request.params,
      authorize: request.action.requiresAuthorization,
    );
    return SecureMeshMlsResponse.fromJson(output);
  }

  Future<SecureMeshKtResponse> _executeSecureMeshKtRequest({
    required AgentCommandRunner agentService,
    required SecureMeshKtRequest request,
    required SecureMeshMobileBridge bridge,
  }) async {
    late final Map<String, dynamic> output;
    if (_dispatch.isAndroid || _dispatch.isIOS) {
      output = await _runMobileRelayNative(
        bridge: _nativeBridgeForCurrentPlatform(androidBridge: bridge),
        action: request.action.wireName,
        params: request.params,
        authorize: request.action.requiresAuthorization,
      );
    } else {
      output = await _dispatch.runCli(agentService, [
        'mobile',
        'relay',
        'kt',
        _secureMeshKtCliAction(request.action),
        ..._secureMeshKtCliParams(request.params),
      ]);
    }
    return SecureMeshKtResponse.fromJson(output);
  }

  String _secureMeshKtCliAction(SecureMeshKtAction action) => switch (action) {
    SecureMeshKtAction.configureAuthority => 'configure-authority',
    SecureMeshKtAction.publicationRequest => 'publication-request',
    SecureMeshKtAction.revocationRequest => 'revocation-request',
    SecureMeshKtAction.provision => 'provision',
    SecureMeshKtAction.gossip => 'gossip',
    SecureMeshKtAction.selfMonitor => 'self-monitor',
    SecureMeshKtAction.status => 'status',
  };

  List<String> _secureMeshKtCliParams(Map<String, dynamic> params) {
    final args = <String>[];
    for (final entry in params.entries) {
      args
        ..add('--${_camelToKebab(entry.key)}')
        ..add(
          entry.value is Map || entry.value is List
              ? jsonEncode(entry.value)
              : entry.value.toString(),
        );
    }
    return args;
  }

  String _camelToKebab(String value) => value.replaceAllMapped(
    RegExp(r'([a-z0-9])([A-Z])'),
    (match) => '${match.group(1)}-${match.group(2)!.toLowerCase()}',
  );
}
