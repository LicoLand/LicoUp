import 'support/client_controller_scenario_dependencies.dart';
import 'support/client_controller_scenario_environment.dart';
import 'support/client_controller_scenario_json.dart';
import 'support/fake_agent_service.dart';
import 'support/fake_mobile_relay_service.dart';

void registerClientSecureMeshScenarios() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('creates mobile pairing and records secure relay delivery', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-mobile-chat-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final agentService = FakeAgentService()
      ..conversationSessions['codex'] = [
        conversationSessionJson(
          id: 'native-phone-list',
          agentId: 'codex',
          text: 'From native history',
        ),
      ];
    final relayService = FakeMobileRelayService()
      ..queuedCommands = [
        const MobileRelayCommand(
          commandId: 'cmd-1',
          type: 'secure_mesh.envelope',
          payload: {},
          status: 'pending',
          createdAt: '2026-06-12T00:00:00.000Z',
        ),
      ];
    final controller = NoPreloadClientController(
      portableData: PortableDataRoot(dataDirectoryOverride: directory),
      agentService: agentService,
      mobileRelayService: relayService,
    );
    addTearDown(controller.dispose);

    await controller.initialize();
    await controller.scanTargets();
    await controller.createMobilePairing();

    expect(relayService.secureMeshStatusCalls, 0);
    expect(relayService.createPairingCalls, 1);
    expect(controller.mobileRelayActionResult?['pairingCode'], '1234-5678');
    expect(controller.mobilePairingPresentation?.pairingCode, '1234-5678');
    expect(
      controller.mobilePairingPresentation?.inviteText,
      startsWith('licoarc://pair?invite='),
    );
    expect(controller.mobileRelayConfig.lastPairingCode, isEmpty);
    expect(controller.mobileRelayConfig.hasPairing, isTrue);

    await controller.pollMobileRelayOnce();

    expect(relayService.syncCalls, 1);
    expect(relayService.syncAllowInteractionFlags, [isFalse]);
    expect(
      controller.lastMobileRelayCommands.single.type,
      'secure_mesh.envelope',
    );
  });

  test('mobile relay empty background poll keeps current status', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-mobile-empty-sync-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final relayService = FakeMobileRelayService();
    final controller = ClientController(
      portableData: PortableDataRoot(dataDirectoryOverride: directory),
      agentService: FakeAgentService(),
      mobileRelayService: relayService,
    );
    addTearDown(controller.dispose);

    await controller.initialize();
    await controller.createMobilePairing();

    final previousMessage = controller.statusMessage;
    final previousCaption = controller.statusCaption;
    await controller.pollMobileRelayOnce();

    expect(relayService.syncCalls, 1);
    expect(controller.statusMessage, previousMessage);
    expect(controller.statusCaption, previousCaption);
    expect(controller.statusMessage, isNot('正在同步手机中转命令。'));
    expect(controller.statusMessage, isNot('手机中转已同步，暂无新命令。'));
  });

  test(
    'mobile relay authorization-required background poll pauses until manual sync',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-mobile-authorization-sync-',
      );
      addTearDown(() => deleteTempDirectory(directory));
      final relayService = FakeMobileRelayService()
        ..syncError = const LicoClientRpcException('authorization_required');
      final controller = ClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: directory),
        agentService: FakeAgentService(),
        mobileRelayService: relayService,
      );
      addTearDown(controller.dispose);

      await controller.initialize();
      await controller.createMobilePairing();
      await controller.pollMobileRelayOnce();
      await controller.pollMobileRelayOnce();

      expect(relayService.syncCalls, 1);
      expect(relayService.syncAllowInteractionFlags, [isFalse]);
      expect(controller.statusMessage, contains('等待本机授权'));

      relayService.syncError = null;
      await controller.pollMobileRelayOnce(showProgress: true);

      expect(relayService.syncCalls, 2);
      expect(relayService.syncAllowInteractionFlags, [isFalse, isTrue]);
      expect(controller.lastError, isEmpty);
    },
  );

  test('claims mobile pairing from compact invite token', () async {
    final relayService = FakeMobileRelayService();
    final controller = ClientController(
      agentService: FakeAgentService(),
      mobileRelayService: relayService,
    );
    addTearDown(controller.dispose);

    final invite = {
      'gatewayUrl': 'https://relay.example.test',
      'pairingId': 'pair-1',
      'pairingCode': '1234-5678',
      'pcClientId': 'pc-1',
      'pcClientName': 'Mac Studio',
      'pcSecureMesh': {'endpointId': 'pc-1'},
      'e2eePairingSecret': 'secret',
    };
    final token = base64Url
        .encode(utf8.encode(jsonEncode(invite)))
        .replaceAll('=', '');

    await controller.claimMobilePairingInvite('licoarc://pair?invite=$token');

    expect(relayService.claimPairingCalls, 1);
    expect(relayService.lastPairingInvite?['pairingId'], 'pair-1');
    expect(controller.mobileRelayConfig.paired, isTrue);
    expect(controller.scannedTargets.single.target, 'codex');
    expect(controller.selectedConversationAgentId, agentOrchestrationTargetId);
  });

  test('refreshes secure mesh status for the relay adapter panel', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-secure-mesh-status-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final relayService = FakeMobileRelayService();
    final controller = NoPreloadClientController(
      portableData: PortableDataRoot(dataDirectoryOverride: directory),
      agentService: FakeAgentService(),
      mobileRelayService: relayService,
    );
    addTearDown(controller.dispose);
    relayService.secureMeshCapabilityProjection =
        localOnlySecureMeshCapabilityProjectionFixture();

    await controller.initialize();
    await controller.refreshSecureMeshStatus();

    expect(relayService.secureMeshStatusCalls, 1);
    expect(relayService.secureMeshStatusAuthorizeFlags, [true]);
    expect(
      controller.secureMeshStatus?['cryptoCoreStatus'],
      'blocked_for_production',
    );
    expect(controller.statusCaption, 'Secure Mesh');
    expect(
      controller.secureMeshCapabilityProjection?.local.enabled,
      contains('protocol.authenticated_encryption'),
    );
    expect(controller.secureMeshCapabilityProjection?.peer, isNull);
  });

  test(
    'evaluates secure mesh device trust policy for the relay panel',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-secure-mesh-trust-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final relayService = FakeMobileRelayService();
      final controller = ClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: directory),
        agentService: FakeAgentService(),
        mobileRelayService: relayService,
      );
      addTearDown(controller.dispose);

      await controller.evaluateSecureMeshDeviceTrustPolicy(
        identity: const {
          'endpointId': 'pc-a',
          'identityPublicKey': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          'signingPublicKey': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
          'rotationEpoch': 1,
        },
        trustState: 'verified',
      );

      expect(relayService.deviceTrustEvaluateCalls, 1);
      expect(relayService.lastDeviceTrustIdentity?['endpointId'], 'pc-a');
      expect(
        controller.secureMeshDeviceTrustPolicy?['trustState'],
        'unverified',
      );
      expect(
        controller.secureMeshDeviceTrustPolicy?['requestedTrustState'],
        'verified',
      );
      expect(
        controller.secureMeshDeviceTrustPolicy?['decision']?['code'],
        'verification_required',
      );
      expect(controller.statusMessage, 'Secure Mesh 设备信任策略已评估。');
    },
  );

  test('evaluates secure mesh file route for the relay panel', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-secure-mesh-file-route-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final relayService = FakeMobileRelayService();
    final controller = ClientController(
      portableData: PortableDataRoot(dataDirectoryOverride: directory),
      agentService: FakeAgentService(),
      mobileRelayService: relayService,
    );
    addTearDown(controller.dispose);

    await controller.evaluateSecureMeshFileRoute(
      manifest: const {
        'fileId': 'file-a',
        'fileName': 'launch-plan.pdf',
        'mimeType': 'application/pdf',
        'relativePath': 'workspace/reports',
        'totalSize': 16,
        'chunkSize': 8,
        'chunkCount': 2,
      },
    );

    expect(relayService.fileRouteEvaluateCalls, 1);
    expect(relayService.lastFileRouteManifest?['fileId'], 'file-a');
    expect(
      controller.secureMeshFileRoute?['route']?['uploadOperation'],
      'secure_mesh.file_chunk.upload',
    );
    expect(controller.statusMessage, 'Secure Mesh 文件路由已评估。');
  });

  test(
    'evaluates secure mesh file receive destination for the relay panel',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-secure-mesh-file-receive-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final relayService = FakeMobileRelayService();
      final controller = ClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: directory),
        agentService: FakeAgentService(),
        mobileRelayService: relayService,
      );
      controller.localePreference = 'zh';
      addTearDown(controller.dispose);

      await controller.evaluateSecureMeshFileReceiveDestination(
        manifest: const {
          'fileId': 'file-a',
          'fileName': 'launch-plan.pdf',
          'mimeType': 'application/pdf',
          'relativePath': 'workspace/reports',
          'totalSize': 16,
          'chunkSize': 8,
          'chunkCount': 2,
        },
        approvedRoot: 'test-data/approved-root',
      );

      expect(relayService.fileReceiveDestinationEvaluateCalls, 1);
      expect(
        relayService.lastFileReceiveDestinationManifest?['fileId'],
        'file-a',
      );
      expect(relayService.lastApprovedRoot, 'test-data/approved-root');
      expect(
        controller
            .secureMeshFileReceiveDestination?['receivePolicy']?['writeOperation'],
        'secure_mesh.file_receive.write',
      );
      expect(controller.statusMessage, '安全网格文件接收位置已评估。');
    },
  );

  test(
    'skill-sync layers file-sync confirmation then Skill Hub install handoff',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-secure-mesh-skill-sync-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final agentService = FakeAgentService()
        ..skillInstallApplyResult = {
          'ok': true,
          'skillId': 'demo-skill',
          'status': 'installed',
        };
      final relayService = FakeMobileRelayService();
      final controller = ClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: directory),
        agentService: agentService,
        mobileRelayService: relayService,
      );
      controller.localePreference = 'en';
      addTearDown(controller.dispose);

      controller.beginSecureMeshSkillSyncDraft(
        skillId: 'demo-skill',
        version: '1.0.0',
        sourceAgentId: 'codex',
        targetAgentId: 'claude-code',
        packageDigest:
            '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        packageFileName: 'demo-skill.zip',
        packageSize: 32,
      );
      controller.setSecureMeshFileSyncDestination(directory.path);
      await controller.prepareSecureMeshSkillSyncTransfer();
      expect(
        controller.secureMeshSkillSyncDraft?.status,
        SecureMeshSkillSyncStatus.awaitingInstall,
      );

      await controller.confirmSecureMeshSkillSyncInstall(userConfirmed: true);

      expect(agentService.applySkillInstallCalls, 1);
      expect(agentService.installedSkillAgent, 'claude-code');
      expect(agentService.installedSkillName, 'demo-skill');
      expect(
        controller.secureMeshSkillSyncDraft?.status,
        SecureMeshSkillSyncStatus.installed,
      );
      expect(
        controller.secureMeshSkillSyncDraft?.toManifest()['protocolVersion'],
        'secure_mesh.skill_sync.v1',
      );
    },
  );

  test(
    'file-sync GUI flow evaluates route, destination, and local confirmation',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-secure-mesh-file-sync-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final relayService = FakeMobileRelayService();
      final controller = ClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: directory),
        agentService: FakeAgentService(),
        mobileRelayService: relayService,
      );
      controller.localePreference = 'en';
      addTearDown(controller.dispose);

      controller.setSecureMeshFileSyncDraft(
        fileName: 'fixtures/report.pdf',
        totalSize: 16,
        mimeType: 'application/pdf',
      );
      expect(controller.secureMeshFileSyncDraft?.fileName, 'report.pdf');
      expect(
        controller.secureMeshFileSyncDraft?.status,
        SecureMeshFileSyncStatus.drafting,
      );

      controller.setSecureMeshFileSyncDestination(directory.path);
      await controller.prepareSecureMeshFileSyncTransfer();

      expect(relayService.fileRouteEvaluateCalls, 1);
      expect(relayService.fileReceiveDestinationEvaluateCalls, 1);
      expect(relayService.fileReceiveConfirmationEvaluateCalls, 1);
      expect(relayService.lastFileReceiveUserConfirmed, isFalse);
      expect(
        controller.secureMeshFileSyncDraft?.status,
        SecureMeshFileSyncStatus.awaitingConfirmation,
      );
      expect(controller.secureMeshFileSyncTransfers, hasLength(1));
      expect(controller.displayStatusMessage, isNot(contains(directory.path)));
      expect(controller.displayStatusMessage, contains('report.pdf'));

      await controller.confirmSecureMeshFileSyncReceive(userConfirmed: true);

      expect(relayService.fileReceiveConfirmationEvaluateCalls, 2);
      expect(relayService.lastFileReceiveUserConfirmed, isTrue);
      expect(
        controller.secureMeshFileSyncDraft?.status,
        SecureMeshFileSyncStatus.confirmed,
      );
      expect(
        controller
            .secureMeshFileReceiveConfirmation?['receiveConfirmation']?['autoPreviewEnabled'],
        isFalse,
      );
      expect(
        controller
            .secureMeshFileReceiveConfirmation?['receiveConfirmation']?['autoIngestionEnabled'],
        isFalse,
      );
    },
  );

  test(
    'remote-approval registers inbox item, fans out, and resolves without plaintext detail',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-secure-mesh-approval-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final relayService = FakeMobileRelayService();
      final controller = ClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: directory),
        agentService: FakeAgentService(),
        mobileRelayService: relayService,
      );
      controller.localePreference = 'en';
      addTearDown(controller.dispose);

      await controller.ingestSecureMeshApprovalRequest(
        pendingOperationId: 'op-test-1',
        requesterAgentId: 'openclaw',
        targetClientId: 'desktop-a',
        originEndpointId: 'endpoint-origin',
        displaySummary: 'Allow tool use',
        adapterCallbackTokenRef: 'cb-1',
        responseNonce: 'nonce-1',
        expiresAt: '2099-01-01T00:00:00Z',
        trustedEndpointIds: const ['endpoint-origin', 'endpoint-phone'],
        requestedTools: const ['fs.read'],
      );

      expect(relayService.approvalAdapterCapabilityCalls, 1);
      expect(relayService.approvalRequestCalls, 1);
      expect(relayService.approvalFanoutCalls, 1);
      expect(controller.secureMeshApprovalInbox, hasLength(1));
      expect(
        controller.secureMeshApprovalInbox.first.status,
        SecureMeshApprovalStatus.pending,
      );
      expect(
        relayService.lastApprovalRequest?.containsKey('toolArguments'),
        isFalse,
      );

      await controller.resolveSecureMeshApproval(
        pendingOperationId: 'op-test-1',
        allow: true,
        respondingEndpointId: 'endpoint-origin',
        responseNonce: 'nonce-1',
      );
      expect(relayService.approvalRespondCalls, 1);
      expect(relayService.lastApprovalDecision, 'allow');
      expect(
        controller.secureMeshApprovalInbox.first.status,
        SecureMeshApprovalStatus.resolved,
      );
      expect(
        controller.secureMeshApprovalInbox.first.decision,
        SecureMeshApprovalDecision.allow,
      );
    },
  );

  test(
    'mobile relay secure envelope does not expose command body to GUI',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-mobile-runtime-chat-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final agentService = FakeAgentService()
        ..conversationSessions['codex'] = [
          conversationSessionJson(
            id: 'native-phone-runtime',
            agentId: 'codex',
            text: 'After phone runtime send',
          ),
        ];
      final relayService = FakeMobileRelayService()
        ..queuedCommands = [
          const MobileRelayCommand(
            commandId: 'cmd-runtime-1',
            type: 'secure_mesh.envelope',
            payload: {},
            status: 'pending',
            createdAt: '2026-06-12T00:00:00.000Z',
          ),
        ];
      final controller = ClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: directory),
        agentService: agentService,
        mobileRelayService: relayService,
      );
      addTearDown(controller.dispose);

      await controller.initialize();
      await controller.createMobilePairing();
      await controller.pollMobileRelayOnce();

      expect(relayService.syncCalls, 1);
      expect(
        controller.lastMobileRelayCommands.single.type,
        'secure_mesh.envelope',
      );
    },
  );

  test('mobile initialize defers paired computer target refresh', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-mobile-relay-targets-',
    );
    addTearDown(() => deleteTempDirectory(directory));
    final relayService = FakeMobileRelayService()
      ..config = MobileRelayConfig.defaults().copyWith(
        useCustomGateway: true,
        customGatewayUrl: 'https://relay.example.test',
        pairingId: 'pair-1',
        pcClientId: 'pc-1',
        pcClientName: 'MacBook Pro',
        mobileToken: 'mobile-token',
        mobileTokenPresent: true,
        paired: true,
        relayEnabled: false,
      );
    final controller = ClientController(
      portableData: PortableDataRoot(dataDirectoryOverride: directory),
      agentService: FakeAgentService(),
      mobileRelayService: relayService,
      mobileClientRuntimePlatformOverride: true,
    );
    addTearDown(controller.dispose);

    await controller.initialize();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(relayService.refreshPairingStatusCalls, 0);
    expect(relayService.secureMeshStatusCalls, 0);
    expect(controller.scannedTargets, isEmpty);
    expect(controller.selectedConversationAgentId, isEmpty);
    expect(controller.statusCaption, 'Ready');

    await controller.scanTargets();

    expect(relayService.refreshPairingStatusCalls, 1);
    expect(controller.scannedTargets, hasLength(1));
    expect(controller.scannedTargets.single.target, 'codex');
    expect(controller.scannedTargets.single.canRelayRuntime, isTrue);
    expect(controller.selectedConversationAgentId, 'codex');
    expect(controller.statusMessage, '已扫描 1 个目标适配器。');
  });

  test(
    'mobile relay executes decrypted secure mesh command through GUI binding',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-mobile-secure-command-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final relayService = FakeMobileRelayService()
        ..queuedCommands = [
          const MobileRelayCommand(
            commandId: 'cmd-secure-1',
            type: 'secure_mesh.command',
            payload: {
              'secureCommandPayload': {
                'schema': 'licomesh.secure-mesh.command.v1',
                'commandId': 'cmd-secure-1',
                'commandKind': 'client.activity.sync',
                'riskClass': 'read_only',
              },
              'secureCommandContext': {
                'localEndpointId': 'pc-b',
                'senderEndpointId': 'pc-a',
                'senderTrustState': 'verified',
              },
            },
            status: 'pending',
            createdAt: '2026-06-12T00:00:00.000Z',
          ),
        ];
      final controller = ClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: directory),
        agentService: FakeAgentService(),
        mobileRelayService: relayService,
      );
      addTearDown(controller.dispose);

      await controller.initialize();
      await controller.createMobilePairing();
      await controller.pollMobileRelayOnce();

      expect(relayService.syncCalls, 1);
      expect(relayService.commandExecuteCalls, 1);
      expect(
        relayService.lastSecureCommandPayload?['commandKind'],
        'client.activity.sync',
      );
      expect(relayService.lastSecureCommandContext?['localEndpointId'], 'pc-b');
      expect(controller.lastSecureMeshCommandExecutions, hasLength(1));
      expect(controller.lastSecureMeshCommandExecutions.single['ok'], isTrue);
      expect(controller.statusMessage, '已处理 1 条手机中转命令，执行 1 条 Secure Mesh 命令。');
    },
  );
}
