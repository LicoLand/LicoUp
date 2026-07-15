part of 'package:flutter_client/src/platform/mobile_relay/mobile_relay_service.dart';

UnsupportedError _iosMobileRelayUnsupported() {
  return UnsupportedError(
    'This Secure Mesh action is not available on the mobile client.',
  );
}

UnsupportedError _mobileRelayDesktopOnlyUnsupported() {
  return UnsupportedError(
    'This Mobile Relay action must be created by the desktop client.',
  );
}

MobileRelayConfig _mobileRelayConfigFromOutput(Map<String, dynamic> output) {
  final config = output['config'];
  if (config is Map<String, dynamic>) {
    final merged = Map<String, dynamic>.from(config);
    final providers = _authorizedProvidersOutputList(output);
    if (providers.isNotEmpty && merged['authorizedProviders'] is! List) {
      merged['authorizedProviders'] = providers;
    }
    _mergePairedDeviceEcho(merged, output);
    return _mobileRelayConfigFromJson(merged);
  }
  final merged = Map<String, dynamic>.from(output);
  final providers = _authorizedProvidersOutputList(output);
  if (providers.isNotEmpty && merged['authorizedProviders'] is! List) {
    merged['authorizedProviders'] = providers;
  }
  _mergePairedDeviceEcho(merged, output);
  return _mobileRelayConfigFromJson(merged);
}

MobileRelayConfig _mobileRelayConfigFromJson(Map<String, dynamic> json) {
  return MobileRelayConfig.fromJson(
    json,
    defaultGatewayUrl: Platform.environment['LICO_MOBILE_RELAY_GATEWAY_URL'],
    pcClientName: Platform.localHostname,
  );
}

List<Object?> _authorizedProvidersOutputList(Map<String, dynamic> output) {
  final direct = output['authorizedProviders'];
  if (direct is List) {
    return direct;
  }
  final desktop = output['desktopAuthorizedProviders'];
  if (desktop is List) {
    return desktop;
  }
  final pairing = output['pairing'];
  if (pairing is Map) {
    final pc = pairing['pc'];
    if (pc is Map) {
      final providers = pc['authorizedProviders'];
      if (providers is List) {
        return providers;
      }
    }
  }
  return const [];
}

void _mergePairedDeviceEcho(
  Map<String, dynamic> config,
  Map<String, dynamic> output,
) {
  final pairing = output['pairing'];
  final pc = pairing is Map ? pairing['pc'] : null;
  if (pc is! Map) {
    return;
  }
  final pairingId = _firstNonBlankValue([
    output['pairingId'],
    config['pairingId'],
  ]);
  if (pairingId.isEmpty) {
    return;
  }
  final pcClientId = _firstNonBlankValue([
    pc['pcClientId'],
    pc['clientId'],
    pc['id'],
    output['pcClientId'],
    config['pcClientId'],
  ]);
  final pcClientName = _firstNonBlankValue([
    pc['pcClientName'],
    pc['clientName'],
    pc['name'],
    output['pcClientName'],
    config['pcClientName'],
    'Mac',
  ]);
  final devices = config['pairedDevices'] is List
      ? List<Object?>.from(config['pairedDevices'] as List)
      : <Object?>[];
  final providerEcho = config['authorizedProviders'] is List
      ? List<Object?>.from(config['authorizedProviders'] as List)
      : _authorizedProvidersOutputList(output);
  for (var index = 0; index < devices.length; index += 1) {
    final device = devices[index];
    if (device is! Map) {
      continue;
    }
    final existingPairing = (device['pairingId'] ?? '').toString().trim();
    final existingId = (device['pcClientId'] ?? device['id'] ?? '')
        .toString()
        .trim();
    final matches =
        existingPairing == pairingId ||
        (pcClientId.isNotEmpty && existingId == pcClientId);
    if (!matches) {
      continue;
    }
    final updated = Map<String, dynamic>.from(device);
    if (pcClientId.isNotEmpty) {
      updated['id'] = pcClientId;
      updated['pcClientId'] = pcClientId;
    }
    updated['pcClientName'] = pcClientName;
    updated['pairingId'] = pairingId;
    updated['credentialPresent'] = _mobileRelayCredentialPresent(
      config,
      output,
      pairing,
    );
    updated['gatewayUrl'] = _mobileRelayGatewayEcho(config, output);
    if (providerEcho.isNotEmpty) {
      updated['authorizedProviders'] = providerEcho;
    }
    devices[index] = updated;
    config['pairedDevices'] = devices;
    return;
  }
  devices.add({
    'id': pcClientId.isNotEmpty ? pcClientId : pairingId,
    'pcClientId': pcClientId,
    'pcClientName': pcClientName,
    'pairingId': pairingId,
    'credentialPresent': _mobileRelayCredentialPresent(config, output, pairing),
    'gatewayUrl': _mobileRelayGatewayEcho(config, output),
    if (providerEcho.isNotEmpty) 'authorizedProviders': providerEcho,
  });
  config['pairedDevices'] = devices;
}

bool _mobileRelayCredentialPresent(
  Map<String, dynamic> config,
  Map<String, dynamic> output,
  Map pairing,
) {
  final mobile = pairing['mobile'];
  return config['mobileTokenPresent'] == true ||
      output['mobileTokenPresent'] == true ||
      _firstNonBlankValue([
        config['mobileToken'],
        output['mobileToken'],
      ]).isNotEmpty ||
      (mobile is Map &&
          _firstNonBlankValue([
            mobile['mobileToken'],
            mobile['token'],
          ]).isNotEmpty);
}

String _mobileRelayGatewayEcho(
  Map<String, dynamic> config,
  Map<String, dynamic> output,
) {
  final explicit = _firstNonBlankValue([
    output['gatewayUrl'],
    config['gatewayUrl'],
  ]);
  final canonicalExplicit = canonicalMobileRelayGatewayOrigin(explicit);
  if (canonicalExplicit != null &&
      !mobileRelayGatewayIsEphemeralCustom(canonicalExplicit)) {
    return canonicalExplicit;
  }
  final custom = canonicalMobileRelayGatewayOrigin(
    (config['customGatewayUrl'] ?? '').toString(),
  );
  if (config['useCustomGateway'] == true &&
      custom != null &&
      !mobileRelayGatewayIsEphemeralCustom(custom)) {
    return custom;
  }
  final fallback = canonicalMobileRelayGatewayOrigin(
    config['defaultGatewayUrl']?.toString() ?? '',
  );
  return fallback == null || mobileRelayGatewayIsEphemeralCustom(fallback)
      ? licoDefaultMobileRelayGatewayUrl
      : fallback;
}

String _firstNonBlankValue(Iterable<Object?> values) {
  for (final value in values) {
    final text = value?.toString().trim() ?? '';
    if (text.isNotEmpty) {
      return text;
    }
  }
  return '';
}

SecureMeshMobileBridge _nativeBridgeForCurrentPlatform({
  required SecureMeshMobileBridge androidBridge,
}) {
  if (Platform.isIOS) {
    return const SecureMeshIosBridge();
  }
  return androidBridge;
}

Future<Map<String, dynamic>> _runMobileRelayNative({
  required SecureMeshMobileBridge bridge,
  required String action,
  Map<String, dynamic> params = const {},
  bool authorize = false,
}) {
  return bridge.nativeJson({
    'action': action,
    'params': params,
    'authorize': authorize,
  });
}

const int _secureRelayResultPollAttempts = 120;
const int _secureAgentSessionListMaximum = 20;
const int _secureAgentSessionListMaximumBytes = 2 * 1024 * 1024;
const int _secureAgentSessionListMaximumMessages = 2000;
const int _secureAgentMessageMaximumDepth = 8;
const int _secureAgentMessageMaximumTextLength = 256 * 1024;

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
    'commandKind': 'agent.sessions.list',
    'targetAgentId': normalizedAgent,
    'workspaceId': 'default',
    'body': {
      'agent': normalizedAgent,
      'agentId': normalizedAgent,
      'target': normalizedAgent,
      'limit': limit,
      'offset': offset,
    },
  };
  SecureMeshMobileBridge mobileBridge;
  if (Platform.isAndroid) {
    mobileBridge = bridge;
  } else if (Platform.isIOS) {
    mobileBridge = const SecureMeshIosBridge();
  } else {
    return const {
      'ok': false,
      'errorCode': 'secure_agent_sessions_mobile_only',
    };
  }
  final created = await _runMobileRelayNative(
    bridge: mobileBridge,
    action: 'mobile.relay.commands.createSecure',
    params: params,
    authorize: true,
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
    'commandKind': 'agent.sessions.describe',
    'targetAgentId': normalizedAgent,
    'workspaceId': 'default',
    'body': {
      'agent': normalizedAgent,
      'agentId': normalizedAgent,
      'target': normalizedAgent,
      'sessionId': normalizedSession,
      'nativeSessionId': normalizedSession,
    },
  };
  SecureMeshMobileBridge mobileBridge;
  if (Platform.isAndroid) {
    mobileBridge = bridge;
  } else if (Platform.isIOS) {
    mobileBridge = const SecureMeshIosBridge();
  } else {
    return const {
      'ok': false,
      'errorCode': 'secure_agent_sessions_mobile_only',
    };
  }
  final created = await _runMobileRelayNative(
    bridge: mobileBridge,
    action: 'mobile.relay.commands.createSecure',
    params: params,
    authorize: true,
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
  required AgentService agentService,
  required String agentId,
  required String text,
  required String sessionId,
  required String model,
  required String reasoningEffort,
  required SecureMeshMobileBridge bridge,
}) async {
  final body = {
    'agentId': agentId,
    'target': agentId,
    'text': text,
    if (sessionId.trim().isNotEmpty) 'sessionId': sessionId.trim(),
    if (model.trim().isNotEmpty) 'model': model.trim(),
    if (reasoningEffort.trim().isNotEmpty)
      'reasoningEffort': reasoningEffort.trim(),
  };
  final params = {
    'commandKind': 'agent.message.send',
    'targetAgentId': agentId,
    'workspaceId': 'default',
    'body': body,
  };
  if (Platform.isAndroid) {
    final created = await _runMobileRelayNative(
      bridge: bridge,
      action: 'mobile.relay.commands.createSecure',
      params: params,
      authorize: true,
    );
    return _waitForSecureRelayResult(bridge: bridge, created: created);
  }
  if (Platform.isIOS) {
    final iosBridge = const SecureMeshIosBridge();
    final created = await _runMobileRelayNative(
      bridge: iosBridge,
      action: 'mobile.relay.commands.createSecure',
      params: params,
      authorize: true,
    );
    return _waitForSecureRelayResult(bridge: iosBridge, created: created);
  }
  return agentService.runCli([
    'mobile',
    'relay',
    'commands',
    'create-secure',
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

Future<Map<String, dynamic>> _sendSecureProviderMessageThroughRelay({
  required AgentService agentService,
  required String providerId,
  required String text,
  required String model,
  required String reasoningEffort,
  required String profileId,
  required SecureMeshMobileBridge bridge,
}) async {
  final normalizedProvider = providerId.trim().toLowerCase();
  final normalizedProfile = profileId.trim();
  final body = {
    'providerId': normalizedProvider,
    'provider': normalizedProvider,
    if (normalizedProfile.isNotEmpty) 'profile': normalizedProfile,
    if (normalizedProfile.isNotEmpty) 'modelProfile': normalizedProfile,
    'text': text,
    if (model.trim().isNotEmpty) 'model': model.trim(),
    if (reasoningEffort.trim().isNotEmpty)
      'reasoningEffort': reasoningEffort.trim(),
  };
  final params = {
    'commandKind': 'provider.chat.send',
    'workspaceId': 'default',
    'body': body,
  };
  if (Platform.isAndroid) {
    final created = await _runMobileRelayNative(
      bridge: bridge,
      action: 'mobile.relay.commands.createSecure',
      params: params,
      authorize: true,
    );
    return _waitForSecureRelayResult(bridge: bridge, created: created);
  }
  if (Platform.isIOS) {
    final iosBridge = const SecureMeshIosBridge();
    final created = await _runMobileRelayNative(
      bridge: iosBridge,
      action: 'mobile.relay.commands.createSecure',
      params: params,
      authorize: true,
    );
    return _waitForSecureRelayResult(bridge: iosBridge, created: created);
  }
  return agentService.runCli([
    'mobile',
    'relay',
    'commands',
    'create-secure',
    '--command-kind',
    'provider.chat.send',
    '--workspace-id',
    'default',
    '--body',
    jsonEncode(body),
  ]);
}

Future<Map<String, dynamic>> _secureMeshStatus({
  required AgentService agentService,
  required SecureMeshMobileBridge bridge,
  required bool authorize,
}) async {
  if (Platform.isAndroid) {
    return _mobileSecureMeshStatusWithE2ee(bridge, authorize: authorize);
  }
  if (Platform.isIOS) {
    return _mobileSecureMeshStatusWithE2ee(
      const SecureMeshIosBridge(),
      authorize: authorize,
    );
  }
  return agentService.runCli([
    'secure-mesh',
    'status',
    if (authorize) ...['--authorize', 'true', '--hydrate-secrets', 'true'],
  ]);
}

Future<SecureMeshMlsResponse> _executeSecureMeshMlsRequest({
  required SecureMeshMlsRequest request,
  required SecureMeshMobileBridge bridge,
}) async {
  if (!Platform.isAndroid && !Platform.isIOS) {
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
  required AgentService agentService,
  required SecureMeshKtRequest request,
  required SecureMeshMobileBridge bridge,
}) async {
  late final Map<String, dynamic> output;
  if (Platform.isAndroid || Platform.isIOS) {
    output = await _runMobileRelayNative(
      bridge: _nativeBridgeForCurrentPlatform(androidBridge: bridge),
      action: request.action.wireName,
      params: request.params,
      authorize: request.action.requiresAuthorization,
    );
  } else {
    output = await agentService.runCli([
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

Future<Map<String, dynamic>> _executeSecureMeshCommand({
  required AgentService agentService,
  required Map<String, dynamic> payload,
  required Map<String, dynamic> context,
  required String ledgerPath,
  required String completedAt,
}) {
  if (Platform.isIOS) {
    throw _iosMobileRelayUnsupported();
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
  return agentService.runCli(args);
}

Future<Map<String, dynamic>> _evaluateSecureMeshDeviceTrust({
  required AgentService agentService,
  required Map<String, dynamic> identity,
  required Map<String, dynamic>? previousIdentity,
  required String trustState,
  required bool requireVerifiedDevice,
  required bool allowUnverifiedReadOnly,
}) {
  if (Platform.isIOS) {
    throw _iosMobileRelayUnsupported();
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
  return agentService.runCli(args);
}

Future<Map<String, dynamic>> _evaluateSecureMeshFileRoute({
  required AgentService agentService,
  required Map<String, dynamic> manifest,
  required SecureMeshMobileBridge bridge,
}) {
  if (Platform.isAndroid || Platform.isIOS) {
    return _runMobileRelayNative(
      bridge: _nativeBridgeForCurrentPlatform(androidBridge: bridge),
      action: 'secure_mesh.file.route',
      params: {'manifest': manifest},
    );
  }
  return agentService.runCli([
    'secure-mesh',
    'file',
    'route',
    '--manifest',
    jsonEncode(manifest),
  ]);
}

Future<Map<String, dynamic>> _evaluateSecureMeshFileReceiveDestination({
  required AgentService agentService,
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
  if (Platform.isAndroid || Platform.isIOS) {
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
  return agentService.runCli(args);
}

Future<Map<String, dynamic>> _evaluateSecureMeshFileReceiveConfirmation({
  required AgentService agentService,
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
  if (Platform.isAndroid || Platform.isIOS) {
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
  return agentService.runCli(args);
}

Future<Map<String, dynamic>> _evaluateSecureMeshApprovalRequest({
  required AgentService agentService,
  required Map<String, dynamic> request,
  required SecureMeshMobileBridge bridge,
}) {
  if (Platform.isAndroid || Platform.isIOS) {
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
  return agentService.runCli(args);
}

Future<Map<String, dynamic>> _evaluateSecureMeshApprovalFanout({
  required AgentService agentService,
  required String pendingOperationId,
  required SecureMeshMobileBridge bridge,
}) {
  if (Platform.isAndroid || Platform.isIOS) {
    return _runMobileRelayNative(
      bridge: _nativeBridgeForCurrentPlatform(androidBridge: bridge),
      action: 'secure_mesh.approval.fanout',
      params: {'pendingOperationId': pendingOperationId.trim()},
    );
  }
  return agentService.runCli([
    'secure-mesh',
    'approval',
    'fanout',
    '--pending-operation-id',
    pendingOperationId.trim(),
  ]);
}

Future<Map<String, dynamic>> _resolveSecureMeshApproval({
  required AgentService agentService,
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
  if (Platform.isAndroid || Platform.isIOS) {
    return _runMobileRelayNative(
      bridge: _nativeBridgeForCurrentPlatform(androidBridge: bridge),
      action: 'secure_mesh.approval.respond',
      params: params,
    );
  }
  return agentService.runCli([
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
  required AgentService agentService,
  required bool includeResolved,
  required SecureMeshMobileBridge bridge,
}) {
  if (Platform.isAndroid || Platform.isIOS) {
    return _runMobileRelayNative(
      bridge: _nativeBridgeForCurrentPlatform(androidBridge: bridge),
      action: 'secure_mesh.approval.inbox',
      params: {'includeResolved': includeResolved},
    );
  }
  return agentService.runCli([
    'secure-mesh',
    'approval',
    'inbox',
    '--include-resolved',
    includeResolved.toString(),
  ]);
}

Future<Map<String, dynamic>> _evaluateSecureMeshApprovalAdapterCapability({
  required AgentService agentService,
  required String agentId,
  required SecureMeshMobileBridge bridge,
}) {
  if (Platform.isAndroid || Platform.isIOS) {
    return _runMobileRelayNative(
      bridge: _nativeBridgeForCurrentPlatform(androidBridge: bridge),
      action: 'secure_mesh.approval.adapterCapability',
      params: {'agentId': agentId.trim()},
    );
  }
  return agentService.runCli([
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

Future<Map<String, dynamic>> _waitForSecureRelayResult({
  required SecureMeshMobileBridge bridge,
  required Map<String, dynamic> created,
}) async {
  final command = created['command'];
  final commandId = command is Map
      ? (command['commandId'] ?? '').toString()
      : '';
  if (commandId.trim().isEmpty) {
    return const {'ok': false, 'errorCode': 'secure_relay_command_id_missing'};
  }
  for (
    var attempt = 0;
    attempt < _secureRelayResultPollAttempts;
    attempt += 1
  ) {
    await Future<void>.delayed(const Duration(seconds: 1));
    final result = await _runMobileRelayNative(
      bridge: bridge,
      action: 'mobile.relay.commands.resultSecure',
      params: {'commandId': commandId},
      authorize: true,
    );
    final completion = resolveSecureRelayPollResult(
      created: created,
      polled: result,
    );
    if (completion != null) {
      return completion;
    }
  }
  return const {'ok': false, 'errorCode': 'secure_relay_result_timeout'};
}

/// Reduces one Secure Relay result poll into a verified completion.
///
/// A `null` return value means the command is still pending. Successful
/// completions retain the opened result for the conversation consumer. Failed
/// completions expose only a bounded error code and never return decrypted
/// error details.
Map<String, dynamic>? resolveSecureRelayPollResult({
  required Map<String, dynamic> created,
  required Map<String, dynamic> polled,
}) {
  final createdCommand = _secureRelayMap(created['command']);
  final relayCommandId = (createdCommand?['commandId'] ?? '').toString().trim();
  final expectedBinding = _secureRelayMap(created['secureCommandBinding']);
  final expectedPayloadCommandId = (expectedBinding?['payloadCommandId'] ?? '')
      .toString()
      .trim();
  final expectedIdempotencyKey = (expectedBinding?['idempotencyKey'] ?? '')
      .toString()
      .trim();
  final expectedCommandKind = (expectedBinding?['commandKind'] ?? '')
      .toString()
      .trim();
  if (relayCommandId.isEmpty ||
      expectedPayloadCommandId.isEmpty ||
      expectedIdempotencyKey.isEmpty ||
      !_secureRelayCommandKinds.contains(expectedCommandKind)) {
    return _secureRelayFailure('secure_relay_command_binding_invalid');
  }
  final response = _secureRelayMap(polled['response']);
  final responseCommand = _secureRelayMap(response?['command']);
  final responseCommandId = (responseCommand?['commandId'] ?? '')
      .toString()
      .trim();
  if (responseCommandId.isNotEmpty && responseCommandId != relayCommandId) {
    return _secureRelayFailure('secure_relay_command_binding_mismatch');
  }
  final responseStatus = (responseCommand?['status'] ?? '')
      .toString()
      .trim()
      .toLowerCase();
  final openedValue = polled['openedResult'];
  final opened = _secureRelayMap(openedValue);

  if (opened == null) {
    if (polled['ok'] == false) {
      return _secureRelayFailure(
        _redactedSecureRelayErrorCode(
          polled['errorCode'],
          fallback: 'secure_relay_result_fetch_failed',
        ),
      );
    }
    if (openedValue != null ||
        responseStatus == 'completed' ||
        responseStatus == 'failed') {
      return _secureRelayFailure('secure_relay_result_invalid');
    }
    return null;
  }

  final execution = _secureRelayMap(opened['execution']);
  if (execution == null) {
    return _secureRelayFailure('secure_relay_result_invalid');
  }
  if (responseCommandId != relayCommandId ||
      (execution['commandId'] ?? '').toString().trim() !=
          expectedPayloadCommandId ||
      (execution['idempotencyKey'] ?? '').toString().trim() !=
          expectedIdempotencyKey) {
    return _secureRelayFailure('secure_relay_command_binding_mismatch');
  }
  final outcome = (execution['outcome'] ?? '').toString().trim().toLowerCase();
  if (outcome == 'error') {
    return _secureRelayFailure(
      _redactedSecureRelayErrorCode(
        execution['errorCode'],
        fallback: 'secure_relay_execution_failed',
      ),
    );
  }
  if (outcome != 'result' ||
      polled['ok'] != true ||
      responseStatus == 'failed') {
    return _secureRelayFailure('secure_relay_result_invalid');
  }

  final executionOutput = _secureRelayMap(execution['output']);
  if (executionOutput == null) {
    return _secureRelayFailure('secure_relay_result_invalid');
  }
  if (executionOutput['ok'] != true) {
    return _secureRelayFailure(
      _redactedSecureRelayErrorCode(
        executionOutput['errorCode'] ?? executionOutput['code'],
        fallback: 'secure_relay_execution_output_failed',
      ),
    );
  }
  final runtimeOutput = _secureRelayMap(executionOutput['output']);
  if (runtimeOutput == null) {
    return _secureRelayFailure('secure_relay_result_invalid');
  }
  final commandKind = (executionOutput['commandKind'] ?? '').toString().trim();
  if (commandKind != expectedCommandKind) {
    return _secureRelayFailure('secure_relay_command_kind_mismatch');
  }
  if (runtimeOutput['ok'] != true) {
    if (!runtimeOutput.containsKey('ok')) {
      return _secureRelayFailure('secure_relay_result_invalid');
    }
    return _secureRelayFailure(
      _redactedSecureRelayErrorCode(
        runtimeOutput['errorCode'] ?? runtimeOutput['code'],
        fallback: 'secure_relay_runtime_failed',
      ),
    );
  }

  return {...created, 'ok': true, 'result': polled};
}

const Set<String> _secureRelayCommandKinds = {
  'agent.message.send',
  'provider.chat.send',
  'agent.sessions.list',
  'agent.sessions.describe',
};

/// Extracts the read-only native conversation list from a verified Secure
/// Relay completion while rejecting cross-command, cross-agent, and ambiguous
/// continuity projections.
Map<String, dynamic> resolveSecureAgentSessionListResult({
  required Map<String, dynamic> result,
  required String agentId,
  String commandKind = 'agent.sessions.list',
}) {
  final normalizedAgent = agentId.trim();
  final normalizedCommand = commandKind.trim();
  if (normalizedAgent.isEmpty) {
    return const {
      'ok': false,
      'errorCode': 'secure_agent_sessions_agent_id_missing',
    };
  }
  if (normalizedCommand != 'agent.sessions.list' &&
      normalizedCommand != 'agent.sessions.describe') {
    return const {
      'ok': false,
      'errorCode': 'secure_agent_sessions_result_invalid',
    };
  }
  if (result['ok'] != true) {
    return _secureRelayFailure(
      _redactedSecureRelayErrorCode(
        result['errorCode'] ?? result['code'],
        fallback: 'secure_agent_sessions_list_failed',
      ),
    );
  }
  final polled = _secureRelayMap(result['result']);
  final opened = _secureRelayMap(polled?['openedResult']);
  final execution = _secureRelayMap(opened?['execution']);
  final executionOutput = _secureRelayMap(execution?['output']);
  final runtimeOutput = _secureRelayMap(executionOutput?['output']);
  if (execution?['outcome'] != 'result' ||
      executionOutput?['ok'] != true ||
      executionOutput?['commandKind'] != normalizedCommand ||
      runtimeOutput?['ok'] != true ||
      runtimeOutput?['mode'] != 'native-history' ||
      runtimeOutput?['importMode'] != 'precise-adapter' ||
      runtimeOutput?['readOnly'] != true ||
      (runtimeOutput?['agentId'] ?? '').toString().trim() != normalizedAgent) {
    return _secureRelayFailure('secure_agent_sessions_result_invalid');
  }
  final rawSessions = runtimeOutput?['sessions'];
  final page = _secureRelayMap(runtimeOutput?['page']);
  if (rawSessions is! List ||
      rawSessions.length > _secureAgentSessionListMaximum ||
      page == null ||
      page['hasMore'] is! bool) {
    return _secureRelayFailure('secure_agent_sessions_result_invalid');
  }
  try {
    if (utf8.encode(jsonEncode(rawSessions)).length >
        _secureAgentSessionListMaximumBytes) {
      return _secureRelayFailure('secure_agent_sessions_payload_too_large');
    }
  } on Object {
    return _secureRelayFailure('secure_agent_sessions_result_invalid');
  }
  final messageBudget = _SecureAgentMessageBudget();
  final sessionsByProjectionId = <String, Map<String, dynamic>>{};
  final sessionsByNativeId = <String, Map<String, dynamic>>{};
  for (final rawSession in rawSessions) {
    final session = _secureRelayMap(rawSession);
    final projectionId = (session?['id'] ?? '').toString().trim();
    final nativeSessionId = (session?['nativeSessionId'] ?? '')
        .toString()
        .trim();
    final sessionAgent = (session?['agentId'] ?? '').toString().trim();
    if (session == null ||
        projectionId.isEmpty ||
        nativeSessionId.isEmpty ||
        sessionAgent != normalizedAgent ||
        session['native'] != true ||
        session['readOnly'] != true) {
      return _secureRelayFailure('secure_agent_sessions_result_invalid');
    }
    final projection = _secureAgentSessionProjection(
      session,
      normalizedAgent,
      messageBudget,
    );
    if (projection == null) {
      return _secureRelayFailure('secure_agent_sessions_result_invalid');
    }
    final duplicateProjection = sessionsByProjectionId[projectionId];
    if (duplicateProjection != null) {
      if (jsonEncode(duplicateProjection) != jsonEncode(projection)) {
        return _secureRelayFailure('secure_agent_sessions_result_invalid');
      }
      continue;
    }
    sessionsByProjectionId[projectionId] = projection;
    final duplicateNative = sessionsByNativeId[nativeSessionId];
    sessionsByNativeId[nativeSessionId] = duplicateNative == null
        ? projection
        : _preferredSecureAgentSessionProjection(duplicateNative, projection);
  }
  final sessions = sessionsByNativeId.values.toList(growable: false)
    ..sort(_compareSecureAgentSessionProjection);
  return {
    'ok': true,
    'agentId': normalizedAgent,
    'sessions': List<Map<String, dynamic>>.unmodifiable(sessions),
    'hasMore': page['hasMore'] == true,
  };
}

Map<String, dynamic>? _secureAgentSessionProjection(
  Map<String, dynamic> session,
  String agentId,
  _SecureAgentMessageBudget messageBudget,
) {
  final id = session['id'];
  final nativeSessionId = session['nativeSessionId'];
  final sessionAgentId = session['agentId'];
  final title = session['title'];
  final createdAt = session['createdAt'];
  final updatedAt = session['updatedAt'];
  final adapterId = session['adapterId'];
  final rawMessages = session['messages'];
  if (id is! String ||
      id.trim().isEmpty ||
      id.length > 1024 ||
      nativeSessionId is! String ||
      nativeSessionId.trim().isEmpty ||
      nativeSessionId.length > 4096 ||
      sessionAgentId is! String ||
      sessionAgentId.trim() != agentId ||
      title is! String ||
      title.length > 4096 ||
      createdAt is! String ||
      createdAt.length > 128 ||
      updatedAt is! String ||
      updatedAt.length > 128 ||
      adapterId is! String ||
      adapterId.trim().isEmpty ||
      adapterId.length > 128 ||
      rawMessages is! List) {
    return null;
  }
  final messages = <Map<String, dynamic>>[];
  for (final rawMessage in rawMessages) {
    final message = _secureAgentMessageProjection(
      rawMessage,
      messageBudget,
      depth: 0,
    );
    if (message == null) {
      return null;
    }
    messages.add(message);
  }
  return {
    'id': id.trim(),
    'nativeSessionId': nativeSessionId.trim(),
    'agentId': sessionAgentId.trim(),
    'adapterId': adapterId.trim(),
    'title': title,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
    'native': true,
    'readOnly': true,
    'messageCount': messages.length,
    'messages': List<Map<String, dynamic>>.unmodifiable(messages),
  };
}

Map<String, dynamic>? _secureAgentMessageProjection(
  Object? rawMessage,
  _SecureAgentMessageBudget budget, {
  required int depth,
}) {
  if (depth > _secureAgentMessageMaximumDepth ||
      budget.count >= _secureAgentSessionListMaximumMessages) {
    return null;
  }
  final message = _secureRelayMap(rawMessage);
  final id = message?['id'];
  final role = message?['role'];
  final text = message?['text'];
  final createdAt = message?['createdAt'];
  if (message == null ||
      id is! String ||
      id.length > 1024 ||
      role is! String ||
      role.trim().isEmpty ||
      role.length > 64 ||
      text is! String ||
      text.length > _secureAgentMessageMaximumTextLength ||
      createdAt is! String ||
      createdAt.length > 128) {
    return null;
  }
  budget.count += 1;
  final projection = <String, dynamic>{
    'id': id,
    'role': role,
    'text': text,
    'createdAt': createdAt,
  };
  for (final key in ['cardType', 'cardTitle', 'cardSubtitle']) {
    final value = message[key];
    if (value == null) {
      continue;
    }
    if (value is! String || value.length > 4096) {
      return null;
    }
    if (value.isNotEmpty) {
      projection[key] = value;
    }
  }
  final collapsed = message['collapsed'];
  if (collapsed != null && collapsed is! bool) {
    return null;
  }
  if (collapsed == false) {
    projection['collapsed'] = false;
  }
  final rawChildren = message['messages'];
  if (rawChildren != null) {
    if (rawChildren is! List) {
      return null;
    }
    final children = <Map<String, dynamic>>[];
    for (final rawChild in rawChildren) {
      final child = _secureAgentMessageProjection(
        rawChild,
        budget,
        depth: depth + 1,
      );
      if (child == null) {
        return null;
      }
      children.add(child);
    }
    if (children.isNotEmpty) {
      projection['messages'] = List<Map<String, dynamic>>.unmodifiable(
        children,
      );
    }
  }
  return projection;
}

Map<String, dynamic> _preferredSecureAgentSessionProjection(
  Map<String, dynamic> left,
  Map<String, dynamic> right,
) {
  final leftUpdatedAt = DateTime.tryParse(left['updatedAt'] as String);
  final rightUpdatedAt = DateTime.tryParse(right['updatedAt'] as String);
  if (leftUpdatedAt != null && rightUpdatedAt != null) {
    final compared = leftUpdatedAt.compareTo(rightUpdatedAt);
    if (compared != 0) {
      return compared > 0 ? left : right;
    }
  } else if (leftUpdatedAt != null) {
    return left;
  } else if (rightUpdatedAt != null) {
    return right;
  }
  return (left['id'] as String).compareTo(right['id'] as String) <= 0
      ? left
      : right;
}

int _compareSecureAgentSessionProjection(
  Map<String, dynamic> left,
  Map<String, dynamic> right,
) {
  final leftUpdatedAt = DateTime.tryParse(left['updatedAt'] as String);
  final rightUpdatedAt = DateTime.tryParse(right['updatedAt'] as String);
  if (leftUpdatedAt != null && rightUpdatedAt != null) {
    final compared = rightUpdatedAt.compareTo(leftUpdatedAt);
    if (compared != 0) {
      return compared;
    }
  } else if (leftUpdatedAt != null) {
    return -1;
  } else if (rightUpdatedAt != null) {
    return 1;
  }
  return (left['id'] as String).compareTo(right['id'] as String);
}

class _SecureAgentMessageBudget {
  int count = 0;
}

Map<String, dynamic> _secureRelayFailure(String errorCode) {
  return {'ok': false, 'errorCode': errorCode};
}

Map<String, dynamic>? _secureRelayMap(Object? value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    try {
      return Map<String, dynamic>.from(value);
    } on TypeError {
      return null;
    }
  }
  return null;
}

String _redactedSecureRelayErrorCode(
  Object? value, {
  required String fallback,
}) {
  final candidate = value is String ? value.trim() : '';
  if (candidate.isEmpty || candidate.length > 64) {
    return fallback;
  }
  if (!RegExp(r'^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$').hasMatch(candidate)) {
    return fallback;
  }
  return candidate;
}
