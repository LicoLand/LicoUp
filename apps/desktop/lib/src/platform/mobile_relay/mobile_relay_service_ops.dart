part of 'package:flutter_client/src/platform/mobile_relay/mobile_relay_service.dart';

mixin _MobileRelayServiceOps {
  Future<MobileRelayConfig> loadConfig({
    required AgentService agentService,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
    bool authorizeSecrets = false,
  }) async {
    if (Platform.isAndroid || Platform.isIOS) {
      final output = await _runMobileRelayNative(
        bridge: _nativeBridgeForCurrentPlatform(androidBridge: bridge),
        action: 'mobile.relay.config.get',
        params: {
          'authorize': authorizeSecrets,
          'hydrateSecrets': authorizeSecrets,
        },
        authorize: authorizeSecrets,
      );
      return _mobileRelayConfigFromOutput(output);
    }
    final output = await agentService.runCli([
      'mobile',
      'relay',
      'config',
      'get',
      '--authorize',
      authorizeSecrets.toString(),
      '--hydrate-secrets',
      authorizeSecrets.toString(),
    ]);
    return _mobileRelayConfigFromOutput(output);
  }

  Future<void> saveConfig({
    required AgentService agentService,
    required MobileRelayConfig config,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    if (Platform.isAndroid || Platform.isIOS) {
      final params = <String, dynamic>{
        'useCustomGateway': config.useCustomGateway,
        'customGatewayUrl': config.customGatewayUrl,
        'relayEnabled': config.relayEnabled,
        'pcClientId': config.pcClientId,
        'pcClientName': config.pcClientName,
        'pairingId': config.pairingId,
        'paired': config.paired,
      };
      if (config.authorizedProviders.isNotEmpty) {
        params['authorizedProviders'] = config.authorizedProviders
            .map((provider) => provider.toJson())
            .toList(growable: false);
      }
      if (config.mobileToken.trim().isNotEmpty) {
        params['mobileToken'] = config.mobileToken.trim();
      }
      await _runMobileRelayNative(
        bridge: _nativeBridgeForCurrentPlatform(androidBridge: bridge),
        action: 'mobile.relay.config.set',
        params: params,
      );
      return;
    }
    final args = [
      'mobile',
      'relay',
      'config',
      'set',
      '--use-custom-gateway',
      config.useCustomGateway.toString(),
      '--custom-gateway-url',
      config.customGatewayUrl,
      '--relay-enabled',
      config.relayEnabled.toString(),
      '--pc-client-id',
      config.pcClientId,
      '--pc-client-name',
      config.pcClientName,
      '--pairing-id',
      config.pairingId,
      '--paired',
      config.paired.toString(),
    ];
    if (config.mobileToken.trim().isNotEmpty) {
      args.addAll(['--mobile-token', config.mobileToken.trim()]);
    }
    await agentService.runCli(args);
  }

  Future<MobileRelayConfig> resetPairing({
    required AgentService agentService,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    if (Platform.isAndroid || Platform.isIOS) {
      final output = await _runMobileRelayNative(
        bridge: _nativeBridgeForCurrentPlatform(androidBridge: bridge),
        action: 'mobile.relay.config.set',
        params: const {'resetPairing': true},
      );
      return _mobileRelayConfigFromOutput(output);
    }
    final output = await agentService.runCli([
      'mobile',
      'relay',
      'config',
      'set',
      '--reset-pairing',
      'true',
    ]);
    return _mobileRelayConfigFromOutput(output);
  }

  Future<MobileRelayConfig> configureGateway({
    required AgentService agentService,
    required bool useCustomGateway,
    required String customGatewayUrl,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    if (Platform.isAndroid || Platform.isIOS) {
      final output = await _runMobileRelayNative(
        bridge: _nativeBridgeForCurrentPlatform(androidBridge: bridge),
        action: 'mobile.relay.config.set',
        params: {
          'useCustomGateway': useCustomGateway,
          'customGatewayUrl': customGatewayUrl.trim(),
        },
      );
      return _mobileRelayConfigFromOutput(output);
    }
    final output = await agentService.runCli([
      'mobile',
      'relay',
      'config',
      'set',
      '--use-custom-gateway',
      useCustomGateway.toString(),
      '--custom-gateway-url',
      customGatewayUrl.trim(),
    ]);
    return _mobileRelayConfigFromOutput(output);
  }

  Future<Map<String, dynamic>> createPairing({
    required AgentService agentService,
  }) {
    if (Platform.isIOS) {
      throw _mobileRelayDesktopOnlyUnsupported();
    }
    return agentService.runCli(['mobile', 'relay', 'pairing', 'create']);
  }

  Future<Map<String, dynamic>> refreshPairingStatus({
    required AgentService agentService,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) {
    if (Platform.isAndroid || Platform.isIOS) {
      return _runMobileRelayNative(
        bridge: _nativeBridgeForCurrentPlatform(androidBridge: bridge),
        action: 'mobile.relay.pairing.status',
      );
    }
    return agentService.runCli(['mobile', 'relay', 'pairing', 'status']);
  }

  Future<Map<String, dynamic>> syncCommands({
    required AgentService agentService,
    bool allowInteraction = true,
  }) {
    if (Platform.isIOS) {
      throw _mobileRelayDesktopOnlyUnsupported();
    }
    return agentService.runCli([
      'mobile',
      'relay',
      'commands',
      'sync',
      '--allow-interaction',
      allowInteraction.toString(),
    ]);
  }

  Future<Map<String, dynamic>> claimPairing({
    required AgentService agentService,
    required Map<String, dynamic> invite,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) {
    if (Platform.isAndroid || Platform.isIOS) {
      return _runMobileRelayNative(
        bridge: _nativeBridgeForCurrentPlatform(androidBridge: bridge),
        action: 'mobile.relay.pairing.claim',
        params: {'invite': invite},
        authorize: true,
      );
    }
    return agentService.runCli([
      'mobile',
      'relay',
      'pairing',
      'claim',
      '--invite',
      jsonEncode(invite),
    ]);
  }

  Future<Map<String, dynamic>> sendSecureAgentMessage({
    required AgentService agentService,
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
    required AgentService agentService,
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
    required AgentService agentService,
    required String agentId,
    required String sessionId,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _describeSecureAgentSessionThroughRelay(
    agentId: agentId,
    sessionId: sessionId,
    bridge: bridge,
  );
  Future<Map<String, dynamic>> sendSecureProviderMessage({
    required AgentService agentService,
    required String providerId,
    required String text,
    String model = '',
    String reasoningEffort = '',
    String profileId = '',
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _sendSecureProviderMessageThroughRelay(
    agentService: agentService,
    providerId: providerId,
    text: text,
    model: model,
    reasoningEffort: reasoningEffort,
    profileId: profileId,
    bridge: bridge,
  );
  Future<Map<String, dynamic>> saveMobileProviderApiKey({
    required AgentService agentService,
    required String providerId,
    required String apiKey,
    String mobileAccountId = '',
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    final normalizedProvider = providerId.trim().toLowerCase();
    if (Platform.isAndroid) {
      return _runMobileRelayNative(
        bridge: bridge,
        action: 'mobile.provider.credential.set',
        params: {
          'providerId': normalizedProvider,
          if (mobileAccountId.trim().isNotEmpty)
            'mobileAccountId': mobileAccountId.trim(),
          'apiKey': apiKey.trim(),
          'source': 'local-api-key',
        },
        authorize: true,
      );
    }
    if (Platform.isIOS) {
      return _runMobileRelayNative(
        bridge: _nativeBridgeForCurrentPlatform(androidBridge: bridge),
        action: 'mobile.provider.credential.set',
        params: {
          'providerId': normalizedProvider,
          if (mobileAccountId.trim().isNotEmpty)
            'mobileAccountId': mobileAccountId.trim(),
          'apiKey': apiKey.trim(),
          'source': 'local-api-key',
        },
        authorize: true,
      );
    }
    final provider = mobileAgentProviderOrNull(normalizedProvider);
    if (provider?.authKind == MobileAgentAuthKind.apiKey) {
      final selectedProvider = provider!;
      final profileId = mobileAccountId.trim().isEmpty
          ? selectedProvider.id
          : mobileAccountId.trim();
      return agentService.runCli([
        'model',
        'profiles',
        'set',
        '--profile',
        profileId,
        '--provider',
        selectedProvider.id,
        '--model',
        selectedProvider.defaultModel,
        '--api-key',
        apiKey.trim(),
      ]);
    }
    return {
      'ok': false,
      'status': 'unsupported_provider',
      'providerId': normalizedProvider,
    };
  }

  Future<Map<String, dynamic>> deleteMobileProviderCredential({
    required AgentService agentService,
    required String providerId,
    required String mobileAccountId,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    final normalizedProvider = providerId.trim().toLowerCase();
    final normalizedAccount = mobileAccountId.trim();
    if (Platform.isAndroid || Platform.isIOS) {
      return _runMobileRelayNative(
        bridge: _nativeBridgeForCurrentPlatform(androidBridge: bridge),
        action: 'mobile.provider.credential.delete',
        params: {
          'providerId': normalizedProvider,
          if (normalizedAccount.isNotEmpty)
            'mobileAccountId': normalizedAccount,
        },
        authorize: true,
      );
    }
    if (normalizedAccount.isEmpty) {
      return {
        'ok': false,
        'status': 'mobile_account_id_required',
        'providerId': normalizedProvider,
        'bodyRedacted': true,
      };
    }
    return agentService.runCli([
      'model',
      'profiles',
      'delete',
      '--profile',
      normalizedAccount,
      '--provider',
      normalizedProvider,
    ]);
  }

  Future<Map<String, dynamic>> mobileProviderCredentialStatus({
    required AgentService agentService,
    required String providerId,
    required String mobileAccountId,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) {
    final normalizedProvider = providerId.trim().toLowerCase();
    final normalizedAccount = mobileAccountId.trim();
    if (Platform.isAndroid || Platform.isIOS) {
      return _runMobileRelayNative(
        bridge: _nativeBridgeForCurrentPlatform(androidBridge: bridge),
        action: 'mobile.provider.credential.status',
        params: {
          'providerId': normalizedProvider,
          if (normalizedAccount.isNotEmpty)
            'mobileAccountId': normalizedAccount,
        },
        authorize: true,
      );
    }
    return Future.value({
      'ok': false,
      'status': 'mobile_only',
      'providerId': normalizedProvider,
      'mobileAccountId': normalizedAccount,
      'bodyRedacted': true,
    });
  }

  Future<Map<String, dynamic>> loginMobileProviderOAuth({
    required AgentService agentService,
    required String providerId,
    String mobileAccountId = '',
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) {
    final normalizedProvider = providerId.trim().toLowerCase();
    if (!_supportsLocalMobileProviderOAuth(normalizedProvider)) {
      return Future.value(
        _localMobileProviderOAuthUnavailable(normalizedProvider),
      );
    }
    if (Platform.isAndroid || Platform.isIOS) {
      return _runMobileRelayNative(
        bridge: _nativeBridgeForCurrentPlatform(androidBridge: bridge),
        action: 'mobile.provider.oauth.login',
        params: {
          'providerId': normalizedProvider,
          if (mobileAccountId.trim().isNotEmpty)
            'mobileAccountId': mobileAccountId.trim(),
        },
        authorize: true,
      );
    }
    return Future.value({
      'ok': false,
      'status': 'mobile_only',
      'providerId': normalizedProvider,
    });
  }

  Future<Map<String, dynamic>> completeMobileProviderOAuthCallback({
    required AgentService agentService,
    required String providerId,
    required String callbackUrl,
    String mobileAccountId = '',
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) {
    final normalizedProvider = providerId.trim().toLowerCase();
    if (!_supportsLocalMobileProviderOAuth(normalizedProvider)) {
      return Future.value(
        _localMobileProviderOAuthUnavailable(normalizedProvider),
      );
    }
    if (Platform.isAndroid || Platform.isIOS) {
      return _runMobileRelayNative(
        bridge: _nativeBridgeForCurrentPlatform(androidBridge: bridge),
        action: 'mobile.provider.oauth.completeCallback',
        params: {
          'providerId': normalizedProvider,
          if (mobileAccountId.trim().isNotEmpty)
            'mobileAccountId': mobileAccountId.trim(),
          'callbackUrl': callbackUrl.trim(),
        },
        authorize: true,
      );
    }
    return Future.value({
      'ok': false,
      'status': 'mobile_only',
      'providerId': normalizedProvider,
    });
  }

  Future<Map<String, dynamic>> mobileProviderOAuthStatus({
    required AgentService agentService,
    required String providerId,
    String mobileAccountId = '',
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) {
    final normalizedProvider = providerId.trim().toLowerCase();
    if (!_supportsLocalMobileProviderOAuth(normalizedProvider)) {
      return Future.value(
        _localMobileProviderOAuthUnavailable(normalizedProvider),
      );
    }
    if (Platform.isAndroid || Platform.isIOS) {
      return _runMobileRelayNative(
        bridge: _nativeBridgeForCurrentPlatform(androidBridge: bridge),
        action: 'mobile.provider.oauth.status',
        params: {
          'providerId': normalizedProvider,
          if (mobileAccountId.trim().isNotEmpty)
            'mobileAccountId': mobileAccountId.trim(),
        },
      );
    }
    return Future.value({
      'ok': false,
      'status': 'mobile_only',
      'providerId': normalizedProvider,
    });
  }

  Future<Map<String, dynamic>> openExternalUrl({
    required AgentService agentService,
    required String url,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    final trimmed = url.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null || uri.scheme.toLowerCase() != 'https') {
      return {
        'ok': false,
        'status': 'unsupported_url',
        'message': 'Only https:// external links are allowed.',
      };
    }
    if (Platform.isAndroid || Platform.isIOS) {
      return _runMobileRelayNative(
        bridge: _nativeBridgeForCurrentPlatform(androidBridge: bridge),
        action: 'external.url.open',
        params: {'url': trimmed},
      );
    }
    final executable = Platform.isMacOS
        ? 'open'
        : Platform.isWindows
        ? 'rundll32'
        : 'xdg-open';
    final args = Platform.isWindows
        ? <String>['url.dll,FileProtocolHandler', trimmed]
        : <String>[trimmed];
    final result = await Process.run(executable, args);
    return {
      'ok': result.exitCode == 0,
      'status': result.exitCode == 0 ? 'opened' : 'open_failed',
      'exitCode': result.exitCode,
    };
  }

  Future<Map<String, dynamic>> openMobileProviderWebConversation({
    required AgentService agentService,
    required String providerId,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) {
    final normalizedProvider = providerId.trim().toLowerCase();
    if (Platform.isAndroid) {
      return _runMobileRelayNative(
        bridge: _nativeBridgeForCurrentPlatform(androidBridge: bridge),
        action: 'mobile.provider.web.open',
        params: {'providerId': normalizedProvider},
      );
    }
    return Future.value({
      'ok': false,
      'status': 'mobile_only',
      'providerId': normalizedProvider,
    });
  }

  Future<Map<String, dynamic>> mobileProviderWebConversationSnapshot({
    required AgentService agentService,
    required String providerId,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) {
    final normalizedProvider = providerId.trim().toLowerCase();
    if (Platform.isAndroid) {
      return _runMobileRelayNative(
        bridge: _nativeBridgeForCurrentPlatform(androidBridge: bridge),
        action: 'mobile.provider.web.snapshot',
        params: {'providerId': normalizedProvider},
      );
    }
    return Future.value({
      'ok': false,
      'status': 'mobile_only',
      'providerId': normalizedProvider,
      'messages': const <Map<String, dynamic>>[],
    });
  }

  Future<Map<String, dynamic>> syncMobileProviderCredentialFromRelay({
    required AgentService agentService,
    required String providerId,
    String mobileAccountId = '',
    String profileId = '',
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) {
    if (Platform.isAndroid || Platform.isIOS) {
      return _runMobileRelayNative(
        bridge: _nativeBridgeForCurrentPlatform(androidBridge: bridge),
        action: 'mobile.provider.credential.syncFromRelay',
        params: {
          'providerId': providerId.trim().toLowerCase(),
          if (mobileAccountId.trim().isNotEmpty)
            'mobileAccountId': mobileAccountId.trim(),
          if (profileId.trim().isNotEmpty) 'profileId': profileId.trim(),
        },
      );
    }
    return Future.value({
      'ok': false,
      'status': 'mobile_only',
      'providerId': providerId.trim().toLowerCase(),
    });
  }

  Future<Map<String, dynamic>> sendLocalProviderMessage({
    required AgentService agentService,
    required String providerId,
    required String text,
    String model = '',
    String reasoningEffort = '',
    String mobileAccountId = '',
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) {
    final params = {
      'providerId': providerId.trim().toLowerCase(),
      if (mobileAccountId.trim().isNotEmpty)
        'mobileAccountId': mobileAccountId.trim(),
      'text': text,
      if (model.trim().isNotEmpty) 'model': model.trim(),
      if (reasoningEffort.trim().isNotEmpty)
        'reasoningEffort': reasoningEffort.trim(),
    };
    if (Platform.isAndroid || Platform.isIOS) {
      return _runMobileRelayNative(
        bridge: _nativeBridgeForCurrentPlatform(androidBridge: bridge),
        action: 'mobile.provider.chat.send',
        params: params,
        authorize: true,
      );
    }
    return Future.value({
      'ok': false,
      'status': 'mobile_only',
      'providerId': providerId.trim().toLowerCase(),
    });
  }

  Future<Map<String, dynamic>> secureMeshStatus({
    required AgentService agentService,
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
  Future<SecureMeshMlsResponse> executeSecureMeshMlsRequest({
    required SecureMeshMlsRequest request,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _executeSecureMeshMlsRequest(request: request, bridge: bridge);
  Future<SecureMeshKtResponse> executeSecureMeshKtRequest({
    required AgentService agentService,
    required SecureMeshKtRequest request,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _executeSecureMeshKtRequest(
    agentService: agentService,
    request: request,
    bridge: bridge,
  );
  Future<Map<String, dynamic>> executeSecureMeshCommand({
    required AgentService agentService,
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
    required AgentService agentService,
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
    required AgentService agentService,
    required Map<String, dynamic> manifest,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _evaluateSecureMeshFileRoute(
    agentService: agentService,
    manifest: manifest,
    bridge: bridge,
  );
  Future<Map<String, dynamic>> evaluateSecureMeshFileReceiveDestination({
    required AgentService agentService,
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
    required AgentService agentService,
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
    required AgentService agentService,
    required Map<String, dynamic> request,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _evaluateSecureMeshApprovalRequest(
    agentService: agentService,
    request: request,
    bridge: bridge,
  );
  Future<Map<String, dynamic>> evaluateSecureMeshApprovalFanout({
    required AgentService agentService,
    required String pendingOperationId,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _evaluateSecureMeshApprovalFanout(
    agentService: agentService,
    pendingOperationId: pendingOperationId,
    bridge: bridge,
  );
  Future<Map<String, dynamic>> resolveSecureMeshApproval({
    required AgentService agentService,
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
    required AgentService agentService,
    bool includeResolved = true,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _listSecureMeshApprovalInbox(
    agentService: agentService,
    includeResolved: includeResolved,
    bridge: bridge,
  );
  Future<Map<String, dynamic>> evaluateSecureMeshApprovalAdapterCapability({
    required AgentService agentService,
    required String agentId,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) => _evaluateSecureMeshApprovalAdapterCapability(
    agentService: agentService,
    agentId: agentId,
    bridge: bridge,
  );
}
