import 'dart:convert';
import 'dart:math';

import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/platform/mobile_relay/mobile_relay_native_dispatch.dart';
import 'package:licoup/src/platform/mobile_relay/mobile_relay_secure_result_reducer.dart';
import 'package:licoup/src/platform/secure_mesh/secure_mesh_android_bridge.dart';
import 'package:licoup/src/platform/secure_mesh/secure_mesh_ios_bridge.dart';
import 'package:licoup/src/platform/secure_mesh/secure_mesh_mobile_bridge.dart';

const int _secureRelayResultPollAttempts = 120;
const int _secureAgentSessionListMaximum = 20;

final class MobileRelaySecureConversationOperations {
  const MobileRelaySecureConversationOperations({
    MobileRelayNativeDispatch dispatch =
        const DefaultMobileRelayNativeDispatch(),
    Future<void> Function(Duration duration)? delay,
  }) : _dispatch = dispatch,
       _delay = delay ?? Future<void>.delayed;

  final MobileRelayNativeDispatch _dispatch;
  final Future<void> Function(Duration duration) _delay;

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

  Future<Map<String, dynamic>> sendSecureAgentMessage({
    required AgentCommandRunner agentService,
    required String agentId,
    required String text,
    String sessionId = '',
    String model = '',
    String reasoningEffort = '',
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _sendSecureAgentMessageThroughRelay(
    agentService: agentService,
    agentId: agentId,
    text: text,
    sessionId: sessionId,
    model: model,
    reasoningEffort: reasoningEffort,
    bridge: bridge,
  );

  Future<Map<String, dynamic>> listSecureAgentSessions({
    required String agentId,
    int limit = 20,
    int offset = 0,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _listSecureAgentSessionsThroughRelay(
    agentId: agentId,
    limit: limit,
    offset: offset,
    bridge: bridge,
  );

  Future<Map<String, dynamic>> describeSecureAgentSession({
    required String agentId,
    required String sessionId,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _describeSecureAgentSessionThroughRelay(
    agentId: agentId,
    sessionId: sessionId,
    bridge: bridge,
  );

  Future<Map<String, dynamic>> secureMeshStatus({
    required AgentCommandRunner agentService,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
    bool authorize = false,
  }) => _secureMeshStatus(
    agentService: agentService,
    bridge: bridge,
    authorize: authorize,
  );

  Future<Map<String, dynamic>> secureMeshAndroidRuntimeStatus({
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => bridge.status();

  Future<Map<String, dynamic>> writeSecureMeshAndroidRuntimeStatus({
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => bridge.writeRuntimeStatus();

  Future<Map<String, dynamic>> _listSecureAgentSessionsThroughRelay({
    required String agentId,
    required int limit,
    required int offset,
    required SecureMeshMobileBridge bridge,
  }) async {
    final normalizedAgent = agentId.trim();
    if (normalizedAgent.isEmpty) {
      return const {
        'ok': false,
        'errorCode': 'secure_agent_sessions_agent_id_missing',
      };
    }
    if (limit <= 0 || limit > _secureAgentSessionListMaximum) {
      return const {
        'ok': false,
        'errorCode': 'secure_agent_sessions_limit_invalid',
      };
    }
    if (offset < 0) {
      return const {
        'ok': false,
        'errorCode': 'secure_agent_sessions_offset_invalid',
      };
    }
    final params = {
      'clientIntentId': _newSecureRelayClientIntentId(),
      'commandKind': 'agent.sessions.list',
      'targetAgentId': normalizedAgent,
      'workspaceId': 'default',
      'body': {'limit': limit, 'offset': offset},
    };
    SecureMeshMobileBridge mobileBridge;
    if (_dispatch.isAndroid) {
      mobileBridge = bridge;
    } else if (_dispatch.isIOS) {
      mobileBridge = const SecureMeshIosBridge();
    } else {
      return const {
        'ok': false,
        'errorCode': 'secure_agent_sessions_mobile_only',
      };
    }
    final created = await _createSecureRelayCommand(
      bridge: mobileBridge,
      params: params,
    );
    final completed = await _waitForSecureRelayResult(
      bridge: mobileBridge,
      created: created,
    );
    return resolveSecureAgentSessionListResult(
      result: completed,
      agentId: normalizedAgent,
      commandKind: 'agent.sessions.list',
    );
  }

  Future<Map<String, dynamic>> _describeSecureAgentSessionThroughRelay({
    required String agentId,
    required String sessionId,
    required SecureMeshMobileBridge bridge,
  }) async {
    final normalizedAgent = agentId.trim();
    final normalizedSession = sessionId.trim();
    if (normalizedAgent.isEmpty) {
      return const {
        'ok': false,
        'errorCode': 'secure_agent_sessions_agent_id_missing',
      };
    }
    if (normalizedSession.isEmpty) {
      return const {
        'ok': false,
        'errorCode': 'secure_agent_sessions_session_id_missing',
      };
    }
    final params = {
      'clientIntentId': _newSecureRelayClientIntentId(),
      'commandKind': 'agent.sessions.describe',
      'targetAgentId': normalizedAgent,
      'workspaceId': 'default',
      'body': {
        'sessionId': normalizedSession,
        'nativeSessionId': normalizedSession,
      },
    };
    SecureMeshMobileBridge mobileBridge;
    if (_dispatch.isAndroid) {
      mobileBridge = bridge;
    } else if (_dispatch.isIOS) {
      mobileBridge = const SecureMeshIosBridge();
    } else {
      return const {
        'ok': false,
        'errorCode': 'secure_agent_sessions_mobile_only',
      };
    }
    final created = await _createSecureRelayCommand(
      bridge: mobileBridge,
      params: params,
    );
    final completed = await _waitForSecureRelayResult(
      bridge: mobileBridge,
      created: created,
    );
    return resolveSecureAgentSessionListResult(
      result: completed,
      agentId: normalizedAgent,
      commandKind: 'agent.sessions.describe',
    );
  }

  Future<Map<String, dynamic>> _sendSecureAgentMessageThroughRelay({
    required AgentCommandRunner agentService,
    required String agentId,
    required String text,
    required String sessionId,
    required String model,
    required String reasoningEffort,
    required SecureMeshMobileBridge bridge,
  }) async {
    final body = {
      'text': text,
      if (sessionId.trim().isNotEmpty) 'sessionId': sessionId.trim(),
      if (model.trim().isNotEmpty) 'model': model.trim(),
      if (reasoningEffort.trim().isNotEmpty)
        'reasoningEffort': reasoningEffort.trim(),
    };
    final params = {
      'clientIntentId': _newSecureRelayClientIntentId(),
      'commandKind': 'agent.message.send',
      'targetAgentId': agentId,
      'workspaceId': 'default',
      'body': body,
    };
    if (_dispatch.isAndroid) {
      final created = await _createSecureRelayCommand(
        bridge: bridge,
        params: params,
      );
      return _waitForSecureRelayResult(bridge: bridge, created: created);
    }
    if (_dispatch.isIOS) {
      final iosBridge = const SecureMeshIosBridge();
      final created = await _createSecureRelayCommand(
        bridge: iosBridge,
        params: params,
      );
      return _waitForSecureRelayResult(bridge: iosBridge, created: created);
    }
    return _createSecureRelayCommandViaCli(agentService, [
      'mobile',
      'relay',
      'commands',
      'create-secure',
      '--client-intent-id',
      params['clientIntentId'] as String,
      '--command-kind',
      'agent.message.send',
      '--target-agent-id',
      agentId,
      '--workspace-id',
      'default',
      '--body',
      jsonEncode(body),
    ]);
  }

  Future<Map<String, dynamic>> _createSecureRelayCommand({
    required SecureMeshMobileBridge bridge,
    required Map<String, dynamic> params,
  }) async {
    for (var attempt = 0; attempt < 2; attempt += 1) {
      try {
        return await _runMobileRelayNative(
          bridge: bridge,
          action: 'mobile.relay.commands.createSecure',
          params: params,
          authorize: true,
        );
      } on Object {
        if (attempt == 1) {
          rethrow;
        }
      }
    }
    throw StateError('secure relay create retry exhausted');
  }

  Future<Map<String, dynamic>> _createSecureRelayCommandViaCli(
    AgentCommandRunner agentService,
    List<String> arguments,
  ) async {
    for (var attempt = 0; attempt < 2; attempt += 1) {
      try {
        return await _dispatch.runCli(agentService, arguments);
      } on Object {
        if (attempt == 1) {
          rethrow;
        }
      }
    }
    throw StateError('secure relay CLI create retry exhausted');
  }

  Future<Map<String, dynamic>> _secureMeshStatus({
    required AgentCommandRunner agentService,
    required SecureMeshMobileBridge bridge,
    required bool authorize,
  }) async {
    if (_dispatch.isAndroid) {
      return _mobileSecureMeshStatusWithE2ee(bridge, authorize: authorize);
    }
    if (_dispatch.isIOS) {
      return _mobileSecureMeshStatusWithE2ee(
        const SecureMeshIosBridge(),
        authorize: authorize,
      );
    }
    return _dispatch.runCli(agentService, [
      'secure-mesh',
      'status',
      if (authorize) ...['--authorize', 'true', '--hydrate-secrets', 'true'],
    ]);
  }

  Future<Map<String, dynamic>> _mobileSecureMeshStatusWithE2ee(
    SecureMeshMobileBridge bridge, {
    required bool authorize,
  }) async {
    final nativeProtocolStatus = await _runMobileRelayNative(
      bridge: bridge,
      action: 'secure_mesh.status',
      authorize: false,
    );
    final status = await bridge.status();
    final e2eeStatus = await _runMobileRelayNative(
      bridge: bridge,
      action: 'mobile.relay.e2ee.status',
      params: {'authorize': authorize, 'hydrateSecrets': authorize},
      authorize: authorize,
    );
    final merged = <String, dynamic>{...nativeProtocolStatus, ...status};
    merged['mobileRelayE2eeStatus'] = e2eeStatus;
    merged['mobileRelayE2eeProductionReady'] =
        e2eeStatus['productionReady'] == true;
    final secretStore = e2eeStatus['secretStore'];
    if (secretStore is Map) {
      merged['mobileRelayE2eeSecretStore'] = Map<String, dynamic>.from(
        secretStore,
      );
    }
    final verifiedSessionProjection = e2eeStatus['capabilityProjection'];
    if (verifiedSessionProjection is Map) {
      // Peer and negotiated sets are promoted only from a native-verified, durable
      // Pairwise session. The local-only protocol projection remains the fallback.
      merged['capabilityProjection'] = Map<String, dynamic>.from(
        verifiedSessionProjection,
      );
    }
    return merged;
  }

  Future<Map<String, dynamic>> _waitForSecureRelayResult({
    required SecureMeshMobileBridge bridge,
    required Map<String, dynamic> created,
  }) async {
    final binding = created['secureCommandBinding'];
    final commandId = binding is Map
        ? (binding['payloadCommandId'] ?? '').toString().trim()
        : '';
    final idempotencyKey = binding is Map
        ? (binding['idempotencyKey'] ?? '').toString().trim()
        : '';
    if (created['ok'] != true || commandId.isEmpty || idempotencyKey.isEmpty) {
      return const {
        'ok': false,
        'errorCode': 'secure_relay_command_binding_invalid',
      };
    }
    for (
      var attempt = 0;
      attempt < _secureRelayResultPollAttempts;
      attempt += 1
    ) {
      await _delay(const Duration(seconds: 1));
      final result = await _runMobileRelayNative(
        bridge: bridge,
        action: 'mobile.relay.commands.resultSecure',
        params: {'commandId': commandId, 'idempotencyKey': idempotencyKey},
        authorize: true,
      );
      final completion = resolveSecureRelayPollResult(
        created: created,
        polled: result,
      );
      if (completion != null) {
        if (completion['ok'] != true) {
          return completion;
        }
        final receiptId = (result['resultReceiptId'] ?? '').toString().trim();
        if (receiptId.isEmpty) {
          return const {
            'ok': false,
            'errorCode': 'secure_relay_result_receipt_invalid',
          };
        }
        for (var ackAttempt = 0; ackAttempt < 3; ackAttempt += 1) {
          try {
            final acknowledged = await _runMobileRelayNative(
              bridge: bridge,
              action: 'mobile.relay.commands.resultSecure',
              params: {'acknowledgeReceiptId': receiptId},
              authorize: true,
            );
            if (acknowledged['ok'] == true &&
                acknowledged['acknowledged'] == true) {
              return {...completion, 'resultReceiptAcknowledged': true};
            }
          } on Object {
            // The native acknowledgement is idempotent; retry the same receipt.
          }
        }
        return const {
          'ok': false,
          'errorCode': 'secure_relay_result_ack_failed',
        };
      }
    }
    return const {'ok': false, 'errorCode': 'secure_relay_result_timeout'};
  }
}

String _newSecureRelayClientIntentId() {
  final random = Random.secure();
  final bytes = List<int>.generate(24, (_) => random.nextInt(256));
  return base64UrlEncode(bytes).replaceAll('=', '');
}
