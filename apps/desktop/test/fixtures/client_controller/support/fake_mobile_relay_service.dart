import 'client_controller_scenario_dependencies.dart';
import 'client_controller_scenario_json.dart';
import 'fake_agent_service.dart';

class FakeMobileRelayService extends MobileRelayService {
  FakeMobileRelayService();

  int createPairingCalls = 0;
  int claimPairingCalls = 0;
  int refreshPairingStatusCalls = 0;
  int syncCalls = 0;
  final List<bool> syncAllowInteractionFlags = [];
  int secureMeshStatusCalls = 0;
  final List<bool> loadConfigAuthorizeSecretsFlags = [];
  final List<bool> secureMeshStatusAuthorizeFlags = [];
  Map<String, dynamic>? secureMeshCapabilityProjection;
  int commandExecuteCalls = 0;
  int secureAgentMessageCalls = 0;
  int secureAgentSessionListCalls = 0;
  int secureAgentSessionDescribeCalls = 0;
  int resetPairingCalls = 0;
  int openExternalUrlCalls = 0;
  int deviceTrustEvaluateCalls = 0;
  int fileRouteEvaluateCalls = 0;
  int fileReceiveDestinationEvaluateCalls = 0;
  int fileReceiveConfirmationEvaluateCalls = 0;
  int approvalRequestCalls = 0;
  int approvalFanoutCalls = 0;
  int approvalRespondCalls = 0;
  int approvalInboxCalls = 0;
  int approvalAdapterCapabilityCalls = 0;
  Map<String, dynamic>? lastApprovalRequest;
  String? lastApprovalPendingOperationId;
  String? lastApprovalDecision;
  MobileRelayConfig config = MobileRelayConfig.defaults().copyWith(
    useCustomGateway: true,
    customGatewayUrl: 'https://relay.example.test',
  );
  List<MobileRelayCommand> queuedCommands = const [];
  Object? syncError;
  Map<String, dynamic>? lastSecureCommandPayload;
  Map<String, dynamic>? lastSecureCommandContext;
  Map<String, dynamic>? lastPairingInvite;
  Map<String, dynamic>? lastDeviceTrustIdentity;
  Map<String, dynamic>? lastFileRouteManifest;
  Map<String, dynamic>? lastFileReceiveDestinationManifest;
  bool? lastFileReceiveUserConfirmed;
  String lastApprovedRoot = '';
  String lastAgentId = '';
  String lastAgentText = '';
  String lastAgentSessionId = '';
  String lastSecureAgentSessionListAgentId = '';
  int lastSecureAgentSessionListLimit = 0;
  int lastSecureAgentSessionListOffset = 0;
  String lastSecureAgentSessionDescribeAgentId = '';
  String lastSecureAgentSessionDescribeSessionId = '';
  final Map<String, Map<String, dynamic>> secureAgentSessionDescriptions = {};
  Map<String, dynamic>? secureAgentSessionDescribeResult;
  String lastExternalUrl = '';
  final Map<String, List<Map<String, dynamic>>> secureAgentSessions = {};
  Map<String, dynamic>? secureAgentSessionListResult;

  @override
  Future<MobileRelayConfig> loadConfig({
    required AgentService agentService,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
    bool authorizeSecrets = false,
  }) async {
    loadConfigAuthorizeSecretsFlags.add(authorizeSecrets);
    return config;
  }

  @override
  Future<void> saveConfig({
    required AgentService agentService,
    required MobileRelayConfig config,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    this.config = config;
  }

  @override
  Future<MobileRelayConfig> configureGateway({
    required AgentService agentService,
    required bool useCustomGateway,
    required String customGatewayUrl,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    config = config.copyWith(
      useCustomGateway: useCustomGateway,
      customGatewayUrl: customGatewayUrl,
    );
    return config;
  }

  @override
  Future<MobileRelayConfig> resetPairing({
    required AgentService agentService,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    resetPairingCalls++;
    config = config.copyWith(
      pairingId: '',
      mobileToken: '',
      mobileTokenPresent: false,
      paired: false,
      relayEnabled: false,
      pairedDevices: const [],
    );
    return config;
  }

  @override
  Future<Map<String, dynamic>> createPairing({
    required AgentService agentService,
  }) async {
    createPairingCalls++;
    config = config.copyWith(
      pairingId: 'pair-1',
      pcToken: 'pc-token',
      lastPairingCode: '',
      lastPairingExpiresAt: '',
      paired: false,
      relayEnabled: true,
    );
    return {
      'ok': true,
      'pairingId': 'pair-1',
      'pcToken': 'pc-token',
      'pairingCode': '1234-5678',
      'expiresAt': '2026-06-12T12:00:00.000Z',
      'mobileRelayPairingInvite': {
        'protocolVersion': 'licomesh.mobile-relay.e2ee.v2',
        'oneTime': true,
        'gatewayUrl': 'https://relay.example.test',
        'pairingId': 'pair-1',
        'pairingCode': '1234-5678',
        'pcSecureMesh': {'endpointId': 'pc'},
        'e2eePairingSecret': 'secret',
      },
      'pairing': {'status': 'pending'},
    };
  }

  @override
  Future<Map<String, dynamic>> claimPairing({
    required AgentService agentService,
    required Map<String, dynamic> invite,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    claimPairingCalls++;
    lastPairingInvite = invite;
    config = config.copyWith(
      pairingId: (invite['pairingId'] ?? 'pair-1').toString(),
      pcClientId: (invite['pcClientId'] ?? 'pc-1').toString(),
      pcClientName: (invite['pcClientName'] ?? 'Mac').toString(),
      mobileToken: 'mobile-token',
      paired: true,
      relayEnabled: true,
      pairedDevices: [
        MobileRelayPairedDevice(
          id: (invite['pcClientId'] ?? 'pc-1').toString(),
          label: (invite['pcClientName'] ?? 'Mac').toString(),
          pairingId: (invite['pairingId'] ?? 'pair-1').toString(),
          mobileToken: 'mobile-token',
          credentialPresent: true,
          gatewayUrl: (invite['gatewayUrl'] ?? 'https://relay.example.test')
              .toString(),
        ),
      ],
    );
    return {
      'ok': true,
      'pairingId': config.pairingId,
      'mobileToken': 'mobile-token',
      'pairing': {
        'status': 'paired',
        'pc': {'clientName': config.pcClientName},
        'mobile': {
          'token': ['mobile', 'token'].join('-'),
        },
      },
    };
  }

  @override
  Future<Map<String, dynamic>> refreshPairingStatus({
    required AgentService agentService,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    refreshPairingStatusCalls++;
    return {
      'ok': true,
      'pairing': {
        'status': config.paired ? 'paired' : 'pending',
        'pc': {
          'clientId': config.pcClientId,
          'clientName': config.pcClientName,
          'targets': [
            {
              'target': 'codex',
              'label': 'Codex',
              'kind': 'cli',
              'status': 'detected',
              'configured': true,
              'confidence': 0.9,
              'binaryPath': '/test-bin/codex',
              'adapterStatus': 'implemented',
              'adapterCapabilities': parityReadyAdapterCapabilities,
              'supportedActions': ['runtime.message.send'],
            },
          ],
        },
        'mobile': {'token': config.mobileToken},
      },
    };
  }

  @override
  Future<Map<String, dynamic>> secureMeshStatus({
    required AgentService agentService,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
    bool authorize = true,
  }) async {
    secureMeshStatusCalls++;
    secureMeshStatusAuthorizeFlags.add(authorize);
    return {
      'ok': true,
      'protocolVersion': 'licomesh.secure-mesh.v1',
      'pairwiseCryptoStatus': 'pairwise-runtime-available',
      'mlsCryptoStatus': 'openmls-provider-reload-available',
      'fileCryptoStatus': 'file-aead-available',
      'commandSecurityStatus': 'command-gate-available',
      'deviceTrustStatus': 'device-trust-policy-cli-gui-available',
      'cryptoCoreStatus': 'blocked_for_production',
      if (secureMeshCapabilityProjection != null)
        'capabilityProjection': secureMeshCapabilityProjection,
    };
  }

  @override
  Future<Map<String, dynamic>> syncCommands({
    required AgentService agentService,
    bool allowInteraction = true,
  }) async {
    syncCalls++;
    syncAllowInteractionFlags.add(allowInteraction);
    final error = syncError;
    if (error != null) {
      throw error;
    }
    final commands = queuedCommands;
    queuedCommands = const [];
    return {
      'ok': true,
      'commands': commands.map((command) {
        return {
          'commandId': command.commandId,
          'type': command.type,
          'payload': command.payload,
          'status': command.status,
          'createdAt': command.createdAt,
        };
      }).toList(),
      'completed': commands.map((command) {
        final agentId = (command.payload['agentId'] ?? 'codex').toString();
        final sessions = agentService is FakeAgentService
            ? (agentService.conversationSessions[agentId] ?? const [])
            : const <Map<String, dynamic>>[];
        if (command.type == 'agent.sessions.list') {
          return {
            'command': {
              'commandId': command.commandId,
              'type': command.type,
              'payload': command.payload,
            },
            'ok': true,
            'completion': {
              'command': {
                'result': {'sessions': sessions},
              },
            },
          };
        }
        if (command.type == 'secure_mesh.envelope') {
          return {
            'command': {
              'commandId': command.commandId,
              'type': command.type,
              'payload': command.payload,
            },
            'ok': false,
            'completion': {
              'ok': false,
              'code': 'secure_mesh_endpoint_crypto_runtime_required',
            },
          };
        }
        final text = (command.payload['text'] ?? 'From phone').toString();
        return {
          'command': {
            'commandId': command.commandId,
            'type': command.type,
            'payload': command.payload,
          },
          'ok': true,
          'completion': {
            'command': {
              'result': {
                'ok': true,
                'mode': 'runtime-adapter',
                'adapterId': agentId,
                'output': text,
              },
            },
          },
        };
      }).toList(),
    };
  }

  @override
  Future<Map<String, dynamic>> executeSecureMeshCommand({
    required AgentService agentService,
    required Map<String, dynamic> payload,
    required Map<String, dynamic> context,
    String ledgerPath = '',
    String completedAt = '',
  }) async {
    commandExecuteCalls++;
    lastSecureCommandPayload = payload;
    lastSecureCommandContext = context;
    return {
      'ok': true,
      'evaluation': {'accepted': true, 'shouldExecute': true},
      'execution': {
        'outcome': 'result',
        'output': {'ok': true, 'events': const []},
      },
    };
  }

  @override
  Future<Map<String, dynamic>> sendSecureAgentMessage({
    required AgentService agentService,
    required String agentId,
    required String text,
    String sessionId = '',
    String model = '',
    String reasoningEffort = '',
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    secureAgentMessageCalls++;
    lastAgentId = agentId;
    lastAgentText = text;
    lastAgentSessionId = sessionId;
    final nativeSessionId = sessionId.trim().isNotEmpty
        ? sessionId.trim()
        : 'native-$agentId-relay';
    return {
      'ok': true,
      'result': {
        'openedResult': {
          'execution': {
            'outcome': 'result',
            'output': {
              'ok': true,
              'commandKind': 'agent.message.send',
              'output': {
                'ok': true,
                'agentId': agentId,
                'nativeSessionId': nativeSessionId,
                'threadId': nativeSessionId,
                'sessionId': nativeSessionId,
                'effective': {
                  'model': model.isEmpty ? null : model,
                  'reasoningEffort': reasoningEffort.isEmpty
                      ? null
                      : reasoningEffort,
                },
                'content': 'Codex relay reply',
                'output': 'Codex relay reply',
              },
            },
          },
        },
      },
    };
  }

  @override
  Future<Map<String, dynamic>> listSecureAgentSessions({
    required AgentService agentService,
    required String agentId,
    int limit = 20,
    int offset = 0,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    secureAgentSessionListCalls++;
    lastSecureAgentSessionListAgentId = agentId;
    lastSecureAgentSessionListLimit = limit;
    lastSecureAgentSessionListOffset = offset;
    final override = secureAgentSessionListResult;
    if (override != null) {
      return Map<String, dynamic>.from(override);
    }
    final all = List<Map<String, dynamic>>.from(
      secureAgentSessions[agentId] ?? const [],
    );
    final start = offset < 0 ? 0 : offset;
    final end = (start + limit).clamp(0, all.length);
    final page = start >= all.length
        ? const <Map<String, dynamic>>[]
        : all.sublist(start, end);
    return {
      'ok': true,
      'agentId': agentId,
      'sessions': page,
      'hasMore': end < all.length,
    };
  }

  @override
  Future<Map<String, dynamic>> describeSecureAgentSession({
    required AgentService agentService,
    required String agentId,
    required String sessionId,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    secureAgentSessionDescribeCalls++;
    lastSecureAgentSessionDescribeAgentId = agentId;
    lastSecureAgentSessionDescribeSessionId = sessionId;
    final override = secureAgentSessionDescribeResult;
    if (override != null) {
      return Map<String, dynamic>.from(override);
    }
    final described = secureAgentSessionDescriptions[sessionId];
    if (described == null) {
      return const {
        'ok': false,
        'errorCode': 'native_session_readback_missing',
      };
    }
    return {
      'ok': true,
      'agentId': agentId,
      'sessions': [Map<String, dynamic>.from(described)],
      'hasMore': false,
    };
  }

  @override
  Future<Map<String, dynamic>> openExternalUrl({
    required AgentService agentService,
    required String url,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    openExternalUrlCalls++;
    lastExternalUrl = url;
    return {'ok': true, 'status': 'opened'};
  }

  @override
  Future<Map<String, dynamic>> evaluateSecureMeshDeviceTrust({
    required AgentService agentService,
    required Map<String, dynamic> identity,
    Map<String, dynamic>? previousIdentity,
    String trustState = 'unverified',
    bool requireVerifiedDevice = true,
    bool allowUnverifiedReadOnly = false,
  }) async {
    deviceTrustEvaluateCalls++;
    lastDeviceTrustIdentity = identity;
    return {
      'ok': true,
      'trustState': 'unverified',
      'requestedTrustState': trustState,
      'decision': {
        'code': 'verification_required',
        'allowedForPrekey': false,
        'allowedForHighRiskCommand': false,
      },
    };
  }

  @override
  Future<Map<String, dynamic>> evaluateSecureMeshFileRoute({
    required AgentService agentService,
    required Map<String, dynamic> manifest,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    fileRouteEvaluateCalls++;
    lastFileRouteManifest = manifest;
    return {
      'ok': true,
      'route': {
        'uploadOperation': 'secure_mesh.file_chunk.upload',
        'fetchOperation': 'secure_mesh.file_chunk.fetch',
      },
    };
  }

  @override
  Future<Map<String, dynamic>> evaluateSecureMeshFileReceiveDestination({
    required AgentService agentService,
    required Map<String, dynamic> manifest,
    required String approvedRoot,
    String conflictPolicy = 'fail_if_exists',
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    fileReceiveDestinationEvaluateCalls++;
    lastFileReceiveDestinationManifest = manifest;
    lastApprovedRoot = approvedRoot;
    return {
      'ok': true,
      'receivePolicy': {
        'destinationApproved': true,
        'requiresUserApprovedRoot': true,
        'destinationPathRedacted': true,
        'conflictPolicy': conflictPolicy,
        'writeOperation': 'secure_mesh.file_receive.write',
      },
    };
  }

  @override
  Future<Map<String, dynamic>> evaluateSecureMeshFileReceiveConfirmation({
    required AgentService agentService,
    required Map<String, dynamic> manifest,
    required String approvedRoot,
    String conflictPolicy = 'fail_if_exists',
    bool userConfirmed = false,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    fileReceiveConfirmationEvaluateCalls++;
    lastFileReceiveDestinationManifest = manifest;
    lastApprovedRoot = approvedRoot;
    lastFileReceiveUserConfirmed = userConfirmed;
    return {
      'ok': true,
      'receiveConfirmation': {
        'required': true,
        'userVisibleConfirmationRequired': true,
        'userConfirmed': userConfirmed,
        'writeAllowed': userConfirmed,
        'localWriteDeferredUntilConfirmed': !userConfirmed,
        'decryptedBytesHiddenUntilConfirmed': true,
        'autoPreviewEnabled': false,
        'autoIngestionEnabled': false,
        'receiveOperation': 'secure_mesh.file_receive.confirm',
      },
    };
  }

  @override
  Future<Map<String, dynamic>> evaluateSecureMeshApprovalRequest({
    required AgentService agentService,
    required Map<String, dynamic> request,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    approvalRequestCalls++;
    lastApprovalRequest = request;
    return {
      'ok': true,
      'pendingOperationId': request['pendingOperationId'],
      'plaintextRelayBlocked': true,
    };
  }

  @override
  Future<Map<String, dynamic>> evaluateSecureMeshApprovalFanout({
    required AgentService agentService,
    required String pendingOperationId,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    approvalFanoutCalls++;
    lastApprovalPendingOperationId = pendingOperationId;
    return {
      'ok': true,
      'fanoutRequired': true,
      'trustedEndpointCount': 2,
      'plaintextRelayBlocked': true,
    };
  }

  @override
  Future<Map<String, dynamic>> resolveSecureMeshApproval({
    required AgentService agentService,
    required String pendingOperationId,
    required String decision,
    required String respondingEndpointId,
    required String responseNonce,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    approvalRespondCalls++;
    lastApprovalPendingOperationId = pendingOperationId;
    lastApprovalDecision = decision;
    return {
      'ok': true,
      'pendingOperationId': pendingOperationId,
      'decision': decision,
      'plaintextRelayBlocked': true,
    };
  }

  @override
  Future<Map<String, dynamic>> listSecureMeshApprovalInbox({
    required AgentService agentService,
    bool includeResolved = true,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    approvalInboxCalls++;
    return {
      'ok': true,
      'plaintextRelayBlocked': true,
      'items': const [],
      'pendingCount': 0,
    };
  }

  @override
  Future<Map<String, dynamic>> evaluateSecureMeshApprovalAdapterCapability({
    required AgentService agentService,
    required String agentId,
    SecureMeshMobileBridge bridge = const SecureMeshAndroidBridge(),
  }) async {
    approvalAdapterCapabilityCalls++;
    return {
      'ok': true,
      'agentId': agentId,
      'approvalsSupported': true,
      'remoteApprovalBridge': true,
      'permissionSelection': 'callback',
      'driversRegistryApprovalsEnabled': false,
      'failClosedWithoutUserDecision': true,
    };
  }
}
