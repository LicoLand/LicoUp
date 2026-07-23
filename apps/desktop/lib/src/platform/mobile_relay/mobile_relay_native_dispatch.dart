import 'dart:io';

import 'package:flutter_client/src/contracts/agent_command_runner.dart';
import 'package:flutter_client/src/contracts/generated/secure_mesh.g.dart';
import 'package:flutter_client/src/platform/native_client/native_cli_ports.dart';
import 'package:flutter_client/src/platform/secure_mesh/secure_mesh_ios_bridge.dart';
import 'package:flutter_client/src/platform/secure_mesh/secure_mesh_mobile_bridge.dart';

abstract interface class MobileRelayNativeDispatch {
  bool get isAndroid;

  bool get isIOS;

  SecureMeshMobileBridge bridgeForCurrentPlatform(
    SecureMeshMobileBridge androidBridge,
  );

  Future<Map<String, dynamic>> runCli(
    AgentCommandRunner runner,
    List<String> arguments,
  );

  Future<Map<String, dynamic>> runMobile({
    required SecureMeshMobileBridge bridge,
    required String action,
    Map<String, dynamic> params = const {},
    bool authorize = false,
  });

  Future<Map<String, dynamic>> openExternalHttps(Uri uri);
}

/// Platform dispatch boundary. Errors are deliberately projected to fixed
/// codes; native payloads, process details, and bridge errors are never logged.
final class DefaultMobileRelayNativeDispatch
    implements MobileRelayNativeDispatch {
  const DefaultMobileRelayNativeDispatch();

  @override
  bool get isAndroid => Platform.isAndroid;

  @override
  bool get isIOS => Platform.isIOS;

  @override
  SecureMeshMobileBridge bridgeForCurrentPlatform(
    SecureMeshMobileBridge androidBridge,
  ) {
    return isIOS ? const SecureMeshIosBridge() : androidBridge;
  }

  @override
  Future<Map<String, dynamic>> runCli(
    AgentCommandRunner runner,
    List<String> arguments,
  ) async {
    try {
      return await runner.runCli(List<String>.unmodifiable(arguments));
    } on LicoClientRpcException {
      rethrow;
    } on Object {
      throw const MobileRelayDispatchException('native_command_failed');
    }
  }

  @override
  Future<Map<String, dynamic>> runMobile({
    required SecureMeshMobileBridge bridge,
    required String action,
    Map<String, dynamic> params = const {},
    bool authorize = false,
  }) async {
    try {
      if (action.startsWith('secure_mesh.')) {
        final result = await bridge.execute(
          SecureMeshRequest(
            action: SecureMeshAction.fromWire(action),
            params: Map<String, Object?>.from(params),
            authorize: authorize,
          ),
        );
        return Map<String, dynamic>.from(result.value);
      }
      return await bridge.nativeJson({
        'action': action,
        'params': Map<String, dynamic>.unmodifiable(params),
        'authorize': authorize,
      });
    } on Object {
      throw const MobileRelayDispatchException('native_bridge_failed');
    }
  }

  @override
  Future<Map<String, dynamic>> openExternalHttps(Uri uri) async {
    final executable = Platform.isMacOS
        ? 'open'
        : Platform.isWindows
        ? 'rundll32'
        : 'xdg-open';
    final arguments = Platform.isWindows
        ? <String>['url.dll,FileProtocolHandler', uri.toString()]
        : <String>[uri.toString()];
    try {
      final result = await Process.run(executable, arguments);
      return {
        'ok': result.exitCode == 0,
        'status': result.exitCode == 0 ? 'opened' : 'open_failed',
        'exitCode': result.exitCode,
      };
    } on Object {
      return const {'ok': false, 'status': 'open_failed', 'exitCode': -1};
    }
  }
}

final class MobileRelayDispatchException implements Exception {
  const MobileRelayDispatchException(this.code);

  final String code;

  @override
  String toString() => 'Mobile Relay dispatch failed (code: $code).';
}
