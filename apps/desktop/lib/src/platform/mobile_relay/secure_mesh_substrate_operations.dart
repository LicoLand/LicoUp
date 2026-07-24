import 'dart:convert';

import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/platform/mobile_relay/mobile_relay_native_dispatch.dart';
import 'package:licoup/src/platform/secure_mesh/secure_mesh_android_bridge.dart';
import 'package:licoup/src/platform/secure_mesh/secure_mesh_mobile_bridge.dart';

final class SecureMeshSubstrateOperations {
  const SecureMeshSubstrateOperations({
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

  Future<Map<String, dynamic>> executeSecureMeshCommand({
    required AgentCommandRunner agentService,
    required Map<String, dynamic> payload,
    required Map<String, dynamic> context,
    String ledgerPath = '',
    String completedAt = '',
  }) => _executeSecureMeshCommand(
    agentService: agentService,
    payload: payload,
    context: context,
    ledgerPath: ledgerPath,
    completedAt: completedAt,
  );

  Future<Map<String, dynamic>> evaluateSecureMeshDeviceTrust({
    required AgentCommandRunner agentService,
    required Map<String, dynamic> identity,
    Map<String, dynamic>? previousIdentity,
    String trustState = 'unverified',
    bool requireVerifiedDevice = true,
    bool allowUnverifiedReadOnly = false,
  }) => _evaluateSecureMeshDeviceTrust(
    agentService: agentService,
    identity: identity,
    previousIdentity: previousIdentity,
    trustState: trustState,
    requireVerifiedDevice: requireVerifiedDevice,
    allowUnverifiedReadOnly: allowUnverifiedReadOnly,
  );

  Future<Map<String, dynamic>> evaluateSecureMeshFileRoute({
    required AgentCommandRunner agentService,
    required Map<String, dynamic> manifest,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _evaluateSecureMeshFileRoute(
    agentService: agentService,
    manifest: manifest,
    bridge: bridge,
  );

  Future<Map<String, dynamic>> evaluateSecureMeshFileReceiveDestination({
    required AgentCommandRunner agentService,
    required Map<String, dynamic> manifest,
    required String approvedRoot,
    String conflictPolicy = 'fail_if_exists',
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _evaluateSecureMeshFileReceiveDestination(
    agentService: agentService,
    manifest: manifest,
    approvedRoot: approvedRoot,
    conflictPolicy: conflictPolicy,
    bridge: bridge,
  );

  Future<Map<String, dynamic>> evaluateSecureMeshFileReceiveConfirmation({
    required AgentCommandRunner agentService,
    required Map<String, dynamic> manifest,
    required String approvedRoot,
    String conflictPolicy = 'fail_if_exists',
    bool userConfirmed = false,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _evaluateSecureMeshFileReceiveConfirmation(
    agentService: agentService,
    manifest: manifest,
    approvedRoot: approvedRoot,
    conflictPolicy: conflictPolicy,
    userConfirmed: userConfirmed,
    bridge: bridge,
  );

  Future<Map<String, dynamic>> evaluateSecureMeshApprovalRequest({
    required AgentCommandRunner agentService,
    required Map<String, dynamic> request,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _evaluateSecureMeshApprovalRequest(
    agentService: agentService,
    request: request,
    bridge: bridge,
  );

  Future<Map<String, dynamic>> evaluateSecureMeshApprovalFanout({
    required AgentCommandRunner agentService,
    required String pendingOperationId,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _evaluateSecureMeshApprovalFanout(
    agentService: agentService,
    pendingOperationId: pendingOperationId,
    bridge: bridge,
  );

  Future<Map<String, dynamic>> resolveSecureMeshApproval({
    required AgentCommandRunner agentService,
    required String pendingOperationId,
    required String decision,
    required String respondingEndpointId,
    required String responseNonce,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _resolveSecureMeshApproval(
    agentService: agentService,
    pendingOperationId: pendingOperationId,
    decision: decision,
    respondingEndpointId: respondingEndpointId,
    responseNonce: responseNonce,
    bridge: bridge,
  );

  Future<Map<String, dynamic>> listSecureMeshApprovalInbox({
    required AgentCommandRunner agentService,
    bool includeResolved = true,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _listSecureMeshApprovalInbox(
    agentService: agentService,
    includeResolved: includeResolved,
    bridge: bridge,
  );

  Future<Map<String, dynamic>> evaluateSecureMeshApprovalAdapterCapability({
    required AgentCommandRunner agentService,
    required String agentId,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _evaluateSecureMeshApprovalAdapterCapability(
    agentService: agentService,
    agentId: agentId,
    bridge: bridge,
  );

  Future<Map<String, dynamic>> _executeSecureMeshCommand({
    required AgentCommandRunner agentService,
    required Map<String, dynamic> payload,
    required Map<String, dynamic> context,
    required String ledgerPath,
    required String completedAt,
  }) {
    if (_dispatch.isAndroid || _dispatch.isIOS) {
      if (ledgerPath.trim().isNotEmpty) {
        throw const MobileRelayDispatchException(
          'mobile_custom_ledger_path_forbidden',
        );
      }
      return _runMobileRelayNative(
        bridge: _nativeBridgeForCurrentPlatform(
          androidBridge: const SecureMeshAndroidBridge(),
        ),
        action: 'secure_mesh.command.execute',
        params: {
          'payload': payload,
          'context': context,
          if (completedAt.trim().isNotEmpty) 'completedAt': completedAt.trim(),
        },
        authorize: true,
      );
    }
    final args = [
      'secure-mesh',
      'command',
      'execute',
      '--payload',
      jsonEncode(payload),
      '--context',
      jsonEncode(context),
    ];
    if (ledgerPath.trim().isNotEmpty) {
      args.addAll(['--ledger-path', ledgerPath.trim()]);
    }
    if (completedAt.trim().isNotEmpty) {
      args.addAll(['--completed-at', completedAt.trim()]);
    }
    return _dispatch.runCli(agentService, args);
  }

  Future<Map<String, dynamic>> _evaluateSecureMeshDeviceTrust({
    required AgentCommandRunner agentService,
    required Map<String, dynamic> identity,
    required Map<String, dynamic>? previousIdentity,
    required String trustState,
    required bool requireVerifiedDevice,
    required bool allowUnverifiedReadOnly,
  }) {
    final params = {
      'identity': identity,
      'previousIdentity': ?previousIdentity,
      'trustState': trustState,
      'requireVerifiedDevice': requireVerifiedDevice,
      'allowUnverifiedReadOnly': allowUnverifiedReadOnly,
    };
    if (_dispatch.isAndroid || _dispatch.isIOS) {
      return _runMobileRelayNative(
        bridge: _nativeBridgeForCurrentPlatform(
          androidBridge: const SecureMeshAndroidBridge(),
        ),
        action: 'secure_mesh.deviceTrust.evaluate',
        params: params,
      );
    }
    final args = [
      'secure-mesh',
      'device-trust',
      'evaluate',
      '--identity',
      jsonEncode(identity),
      '--trust-state',
      trustState,
      '--require-verified-device',
      requireVerifiedDevice.toString(),
      '--allow-unverified-read-only',
      allowUnverifiedReadOnly.toString(),
    ];
    if (previousIdentity != null) {
      args.addAll(['--previous-identity', jsonEncode(previousIdentity)]);
    }
    return _dispatch.runCli(agentService, args);
  }

  Future<Map<String, dynamic>> _evaluateSecureMeshFileRoute({
    required AgentCommandRunner agentService,
    required Map<String, dynamic> manifest,
    required SecureMeshMobileBridge bridge,
  }) {
    if (_dispatch.isAndroid || _dispatch.isIOS) {
      return _runMobileRelayNative(
        bridge: _nativeBridgeForCurrentPlatform(androidBridge: bridge),
        action: 'secure_mesh.file.route',
        params: {'manifest': manifest},
      );
    }
    return _dispatch.runCli(agentService, [
      'secure-mesh',
      'file',
      'route',
      '--manifest',
      jsonEncode(manifest),
    ]);
  }

  Future<Map<String, dynamic>> _evaluateSecureMeshFileReceiveDestination({
    required AgentCommandRunner agentService,
    required Map<String, dynamic> manifest,
    required String approvedRoot,
    required String conflictPolicy,
    required SecureMeshMobileBridge bridge,
  }) {
    final params = {
      'manifest': manifest,
      'approvedRoot': approvedRoot.trim(),
      if (conflictPolicy.trim().isNotEmpty)
        'conflictPolicy': conflictPolicy.trim(),
    };
    if (_dispatch.isAndroid || _dispatch.isIOS) {
      return _runMobileRelayNative(
        bridge: _nativeBridgeForCurrentPlatform(androidBridge: bridge),
        action: 'secure_mesh.file.receiveDestination',
        params: params,
      );
    }
    final args = [
      'secure-mesh',
      'file',
      'receive-destination',
      '--manifest',
      jsonEncode(manifest),
      '--approved-root',
      approvedRoot.trim(),
    ];
    if (conflictPolicy.trim().isNotEmpty) {
      args.addAll(['--conflict-policy', conflictPolicy.trim()]);
    }
    return _dispatch.runCli(agentService, args);
  }

  Future<Map<String, dynamic>> _evaluateSecureMeshFileReceiveConfirmation({
    required AgentCommandRunner agentService,
    required Map<String, dynamic> manifest,
    required String approvedRoot,
    required String conflictPolicy,
    required bool userConfirmed,
    required SecureMeshMobileBridge bridge,
  }) {
    final params = {
      'manifest': manifest,
      'approvedRoot': approvedRoot.trim(),
      'userConfirmed': userConfirmed,
      if (conflictPolicy.trim().isNotEmpty)
        'conflictPolicy': conflictPolicy.trim(),
    };
    if (_dispatch.isAndroid || _dispatch.isIOS) {
      return _runMobileRelayNative(
        bridge: _nativeBridgeForCurrentPlatform(androidBridge: bridge),
        action: 'secure_mesh.file.receiveConfirmation',
        params: params,
      );
    }
    final args = [
      'secure-mesh',
      'file',
      'receive-confirmation',
      '--manifest',
      jsonEncode(manifest),
      '--approved-root',
      approvedRoot.trim(),
      '--user-confirmed',
      userConfirmed.toString(),
    ];
    if (conflictPolicy.trim().isNotEmpty) {
      args.addAll(['--conflict-policy', conflictPolicy.trim()]);
    }
    return _dispatch.runCli(agentService, args);
  }

  Future<Map<String, dynamic>> _evaluateSecureMeshApprovalRequest({
    required AgentCommandRunner agentService,
    required Map<String, dynamic> request,
    required SecureMeshMobileBridge bridge,
  }) {
    if (_dispatch.isAndroid || _dispatch.isIOS) {
      return _runMobileRelayNative(
        bridge: _nativeBridgeForCurrentPlatform(androidBridge: bridge),
        action: 'secure_mesh.approval.request',
        params: request,
      );
    }
    final args = <String>['secure-mesh', 'approval', 'request'];
    for (final entry in request.entries) {
      final value = entry.value;
      if (value == null) {
        continue;
      }
      if (value is List || value is Map) {
        args.addAll(['--${_cliFlag(entry.key)}', jsonEncode(value)]);
      } else {
        args.addAll(['--${_cliFlag(entry.key)}', value.toString()]);
      }
    }
    return _dispatch.runCli(agentService, args);
  }

  Future<Map<String, dynamic>> _evaluateSecureMeshApprovalFanout({
    required AgentCommandRunner agentService,
    required String pendingOperationId,
    required SecureMeshMobileBridge bridge,
  }) {
    if (_dispatch.isAndroid || _dispatch.isIOS) {
      return _runMobileRelayNative(
        bridge: _nativeBridgeForCurrentPlatform(androidBridge: bridge),
        action: 'secure_mesh.approval.fanout',
        params: {'pendingOperationId': pendingOperationId.trim()},
      );
    }
    return _dispatch.runCli(agentService, [
      'secure-mesh',
      'approval',
      'fanout',
      '--pending-operation-id',
      pendingOperationId.trim(),
    ]);
  }

  Future<Map<String, dynamic>> _resolveSecureMeshApproval({
    required AgentCommandRunner agentService,
    required String pendingOperationId,
    required String decision,
    required String respondingEndpointId,
    required String responseNonce,
    required SecureMeshMobileBridge bridge,
  }) {
    final params = {
      'pendingOperationId': pendingOperationId.trim(),
      'decision': decision.trim(),
      'respondingEndpointId': respondingEndpointId.trim(),
      'responseNonce': responseNonce.trim(),
    };
    if (_dispatch.isAndroid || _dispatch.isIOS) {
      return _runMobileRelayNative(
        bridge: _nativeBridgeForCurrentPlatform(androidBridge: bridge),
        action: 'secure_mesh.approval.respond',
        params: params,
      );
    }
    return _dispatch.runCli(agentService, [
      'secure-mesh',
      'approval',
      'respond',
      '--pending-operation-id',
      pendingOperationId.trim(),
      '--decision',
      decision.trim(),
      '--responding-endpoint-id',
      respondingEndpointId.trim(),
      '--response-nonce',
      responseNonce.trim(),
    ]);
  }

  Future<Map<String, dynamic>> _listSecureMeshApprovalInbox({
    required AgentCommandRunner agentService,
    required bool includeResolved,
    required SecureMeshMobileBridge bridge,
  }) {
    if (_dispatch.isAndroid || _dispatch.isIOS) {
      return _runMobileRelayNative(
        bridge: _nativeBridgeForCurrentPlatform(androidBridge: bridge),
        action: 'secure_mesh.approval.inbox',
        params: {'includeResolved': includeResolved},
      );
    }
    return _dispatch.runCli(agentService, [
      'secure-mesh',
      'approval',
      'inbox',
      '--include-resolved',
      includeResolved.toString(),
    ]);
  }

  Future<Map<String, dynamic>> _evaluateSecureMeshApprovalAdapterCapability({
    required AgentCommandRunner agentService,
    required String agentId,
    required SecureMeshMobileBridge bridge,
  }) {
    if (_dispatch.isAndroid || _dispatch.isIOS) {
      return _runMobileRelayNative(
        bridge: _nativeBridgeForCurrentPlatform(androidBridge: bridge),
        action: 'secure_mesh.approval.adapterCapability',
        params: {'agentId': agentId.trim()},
      );
    }
    return _dispatch.runCli(agentService, [
      'secure-mesh',
      'approval',
      'adapter-capability',
      '--agent-id',
      agentId.trim(),
    ]);
  }

  String _cliFlag(String key) {
    final buffer = StringBuffer();
    for (var i = 0; i < key.length; i++) {
      final char = key[i];
      final code = char.codeUnitAt(0);
      if (code >= 65 && code <= 90) {
        if (buffer.isNotEmpty) {
          buffer.write('-');
        }
        buffer.write(String.fromCharCode(code + 32));
      } else {
        buffer.write(char);
      }
    }
    return buffer.toString();
  }
}
