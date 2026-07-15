import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_client/src/backend/features/agents/services/agent_conversation_service.dart';
import 'package:flutter_client/src/backend/features/mobile_relay/services/mobile_agent_account_service.dart';
import 'package:flutter_client/src/backend/features/mobile_relay/services/mobile_home_layout_service.dart';
import 'package:flutter_client/src/backend/features/mobile_relay/services/mobile_provider_conversation_service.dart';
import 'package:flutter_client/src/contracts/mobile_home_layout.dart';
import 'package:flutter_client/src/contracts/mobile_provider_conversation.dart';
import 'package:flutter_client/src/platform/native_client/agent_service.dart';
import 'package:flutter_client/src/platform/mobile_relay/mobile_agent_account_store.dart';
import 'package:flutter_client/src/platform/mobile_relay/mobile_home_layout_store.dart';
import 'package:flutter_client/src/platform/mobile_relay/mobile_provider_conversation_store.dart';
import 'package:flutter_client/src/platform/mobile_relay/mobile_relay_service.dart';
import 'package:flutter_client/src/platform/secure_mesh/secure_mesh_android_bridge.dart';
import 'package:flutter_client/src/platform/secure_mesh/secure_mesh_ios_bridge.dart';
import 'package:flutter_client/src/platform/storage/portable_data_root.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'desktop provider credential save and delete use account-scoped CLI',
    () async {
      final calls = <List<String>>[];
      final agentService = AgentService(
        runCliExecutable: (executable, args, environment) async {
          calls.add(List<String>.from(args));
          return ProcessResult(
            0,
            0,
            jsonEncode({
              'ok': true,
              'deleted': args.contains('delete'),
              'credentialDeleted': args.contains('delete'),
            }),
            '',
          );
        },
      );
      const service = MobileRelayService();

      await service.saveMobileProviderApiKey(
        agentService: agentService,
        providerId: 'deepseek',
        mobileAccountId: 'account-a',
        apiKey: '<api-key>',
      );
      final deleted = await service.deleteMobileProviderCredential(
        agentService: agentService,
        providerId: 'deepseek',
        mobileAccountId: 'account-a',
      );

      expect(calls, [
        [
          'model',
          'profiles',
          'set',
          '--profile',
          'account-a',
          '--provider',
          'deepseek',
          '--model',
          'deepseek-v4-flash',
          '--api-key',
          '<api-key>',
        ],
        [
          'model',
          'profiles',
          'delete',
          '--profile',
          'account-a',
          '--provider',
          'deepseek',
        ],
      ]);
      expect(deleted['ok'], isTrue);
      expect(deleted['deleted'], isTrue);
    },
  );

  test('mobile home layout persists through platform storage', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-mobile-home-layout-store-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final portableData = PortableDataRoot(dataDirectoryOverride: directory);
    const service = MobileHomeLayoutService(
      store: PlatformMobileHomeLayoutStore(),
    );

    await service.save(
      portableData,
      const MobileHomeLayout(
        order: ['provider:deepseek', 'agent:codex'],
        pinnedEntryIds: {'agent:codex'},
      ),
    );

    final loaded = await service.load(portableData);

    expect(loaded.order, ['provider:deepseek', 'agent:codex']);
    expect(loaded.pinnedEntryIds, {'agent:codex'});
  });

  test(
    'mobile agent accounts persist through locked platform storage',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-mobile-agent-account-store-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final portableData = PortableDataRoot(dataDirectoryOverride: directory);
      const service = MobileAgentAccountService(
        store: PlatformMobileAgentAccountStore(),
      );

      await service.configureApiCredential(
        portableData,
        'deepseek',
        'deepseek-test-key-1111',
      );

      final loaded = await service.load(portableData);

      expect(loaded, hasLength(1));
      expect(loaded.single.providerId, 'deepseek');
      expect(loaded.single.credentialPresent, isTrue);
      expect(loaded.single.credentialHint, '**** 1111');
    },
  );

  test('mobile agent account store serializes concurrent writes', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-mobile-agent-account-concurrent-store-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final portableData = PortableDataRoot(dataDirectoryOverride: directory);
    const store = PlatformMobileAgentAccountStore();

    await Future.wait([
      for (var index = 0; index < 24; index += 1)
        store.write(portableData, {
          'schemaVersion': 1,
          'accounts': [
            {
              'id': 'chatgpt-$index',
              'providerId': 'chatgpt',
              'label': 'ChatGPT $index',
            },
          ],
        }),
    ]);

    final accountsFile = File(
      '${(await portableData.clientDirectory()).path}/mobile-agent-accounts.json',
    );
    final decoded = jsonDecode(await accountsFile.readAsString());

    expect(decoded, isA<Map<String, dynamic>>());
    expect(decoded['accounts'], isA<List>());
  });

  test(
    'Gemini and Kimi local OAuth surfaces are explicitly deferred',
    () async {
      const service = MobileRelayService();
      final agentService = AgentService();
      for (final providerId in const ['gemini', 'kimi']) {
        final start = await service.loginMobileProviderOAuth(
          agentService: agentService,
          providerId: providerId,
        );
        final callback = await service.completeMobileProviderOAuthCallback(
          agentService: agentService,
          providerId: providerId,
          callbackUrl: 'https://callback.invalid/',
        );
        final status = await service.mobileProviderOAuthStatus(
          agentService: agentService,
          providerId: providerId,
        );
        for (final result in [start, callback, status]) {
          expect(result['ok'], isFalse);
          expect(result['code'], 'android_provider_deferred');
          expect(result['supportState'], 'deferred_optional_service');
          expect(result['bodyRedacted'], isTrue);
        }
      }
    },
  );

  test(
    'mobile provider conversations purge expired trash from platform storage',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-mobile-provider-conversation-store-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final portableData = PortableDataRoot(dataDirectoryOverride: directory);
      const service = MobileProviderConversationService(
        store: PlatformMobileProviderConversationStore(),
      );
      final now = DateTime.utc(2026, 7, 4, 12);
      AgentConversationSession session(String id) {
        return AgentConversationSession(
          id: id,
          agentId: 'deepseek',
          title: id,
          createdAt: now.toIso8601String(),
          updatedAt: now.toIso8601String(),
          messages: const [],
        );
      }

      await service.save(portableData, [
        MobileProviderConversationRecord(
          accountId: 'deepseek-account',
          providerId: 'deepseek',
          status: mobileProviderConversationStatusActive,
          session: session('active'),
        ),
        MobileProviderConversationRecord(
          accountId: 'deepseek-account',
          providerId: 'deepseek',
          status: mobileProviderConversationStatusTrashed,
          deletedAt: now.subtract(const Duration(days: 31)).toIso8601String(),
          session: session('expired-trash'),
        ),
        MobileProviderConversationRecord(
          accountId: 'deepseek-account',
          providerId: 'deepseek',
          status: mobileProviderConversationStatusTrashed,
          deletedAt: now.subtract(const Duration(days: 2)).toIso8601String(),
          session: session('recent-trash'),
        ),
      ]);

      final loaded = await service.load(portableData, now: now);

      expect(loaded.map((record) => record.session.id), [
        'recent-trash',
        'active',
      ]);
    },
  );

  test(
    'falls back to LicoLite relay when persisted default gateway is blank',
    () {
      final config = MobileRelayConfig.fromJson(const {
        'defaultGatewayUrl': '   ',
        'customGatewayUrl': '',
        'useCustomGateway': false,
      });

      expect(config.defaultGatewayUrl, licoDefaultMobileRelayGatewayUrl);
      expect(config.effectiveGatewayUrl, licoDefaultMobileRelayGatewayUrl);
    },
  );

  test(
    'migrates legacy default gateways to the public app.licoarc.com gateway',
    () {
      final fromRelay = MobileRelayConfig.fromJson(const {
        'defaultGatewayUrl': 'https://relay.licolite.com/',
        'customGatewayUrl': 'https://relay.licolite.com',
        'useCustomGateway': false,
      });
      final fromApi = MobileRelayConfig.fromJson(const {
        'defaultGatewayUrl': 'https://api.licolite.app/',
        'customGatewayUrl': '',
        'useCustomGateway': false,
      });

      expect(fromRelay.defaultGatewayUrl, licoDefaultMobileRelayGatewayUrl);
      expect(fromRelay.customGatewayUrl, 'https://relay.licolite.com');
      expect(fromRelay.effectiveGatewayUrl, licoDefaultMobileRelayGatewayUrl);
      expect(fromApi.defaultGatewayUrl, licoDefaultMobileRelayGatewayUrl);
      expect(fromApi.effectiveGatewayUrl, 'https://app.licoarc.com');
    },
  );

  test('disables stale ephemeral custom relay gateway', () {
    final config = MobileRelayConfig.fromJson(const {
      'defaultGatewayUrl': licoDefaultMobileRelayGatewayUrl,
      'customGatewayUrl': 'https://old-relay.trycloudflare.com/',
      'useCustomGateway': true,
    });

    expect(config.useCustomGateway, isFalse);
    expect(config.customGatewayUrl, isEmpty);
    expect(config.effectiveGatewayUrl, licoDefaultMobileRelayGatewayUrl);

    final copied = config.copyWith(
      useCustomGateway: true,
      customGatewayUrl: 'https://next-relay.trycloudflare.com/',
    );
    expect(copied.useCustomGateway, isFalse);
    expect(copied.customGatewayUrl, isEmpty);
    expect(copied.effectiveGatewayUrl, licoDefaultMobileRelayGatewayUrl);
  });

  test(
    'device tabs collapse stale duplicate pairings for the same computer',
    () {
      final config = MobileRelayConfig.fromJson(const {
        'pairedDevices': [
          {
            'id': 'old-pc',
            'pcClientName': 'Lico Arc',
            'pairingId': 'pair-old',
            'credentialPresent': true,
            'gatewayUrl': 'https://api.licolite.app',
          },
          {
            'id': 'new-pc',
            'pcClientName': 'Lico Arc',
            'pairingId': 'pair-new',
            'credentialPresent': true,
            'gatewayUrl': 'https://api.licolite.app/',
          },
        ],
      });

      expect(config.deviceTabs, hasLength(1));
      expect(config.deviceTabs.single.pairingId, 'pair-new');
      expect(config.deviceTabs.single.label, 'Lico Arc');
    },
  );

  test('device tabs echo paired computer while mobile token is redacted', () {
    final config = MobileRelayConfig.fromJson(const {
      'pairingId': 'pair-1',
      'pcClientId': 'pc-1',
      'pcClientName': 'Mac Studio',
      'paired': true,
      'mobileToken': '',
      'mobileTokenPresent': false,
    });

    expect(config.deviceTabs, hasLength(1));
    expect(config.deviceTabs.single.id, 'pc-1');
    expect(config.deviceTabs.single.label, 'Mac Studio');
    expect(config.deviceTabs.single.pairingId, 'pair-1');
    expect(config.deviceTabs.single.credentialPresent, isFalse);
  });

  test('mobile relay config parses the redacted exact trust presentation', () {
    final config = MobileRelayConfig.fromJson(const {
      'pairingId': 'pair-1',
      'paired': true,
      'pcTokenPresent': true,
      'deviceTrustPresentation': {
        'schemaVersion': 'licolite.secure-mesh.device-trust-presentation.v1',
        'protocolVersion': 'licolite.secure-mesh.device-trust.v2',
        'localFingerprint': 'local-fingerprint',
        'peerFingerprint': 'peer-fingerprint',
        'safetyNumberGroups': [
          '00001',
          '00002',
          '00003',
          '00004',
          '00005',
          '00006',
          '00007',
          '00008',
          '00009',
          '00010',
          '00011',
          '00012',
          'invalid',
        ],
        'qrPayload': 'licolite-trust-qr',
        'trustState': 'verified',
        'verificationMethod': 'pairing_claim_proof',
        'verified': true,
      },
    });

    expect(config.trustPresentation, isNotNull);
    expect(config.trustPresentation!.verified, isTrue);
    expect(config.trustPresentation!.safetyNumberGroups, hasLength(12));
    expect(
      config.trustPresentation!.safetyNumber,
      '00001 00002 00003 00004 00005 00006 00007 00008 00009 00010 00011 00012',
    );
    expect(config.trustPresentation!.blocksProtectedSend, isFalse);
  });

  test(
    'paired device credential keeps existing mobile pairing usable when top-level token is redacted',
    () {
      final config = MobileRelayConfig.fromJson(const {
        'pairingId': 'pair-1',
        'pcClientId': 'pc-1',
        'pcClientName': 'ARC Desktop',
        'paired': false,
        'mobileToken': '',
        'mobileTokenPresent': false,
        'pairedDevices': [
          {
            'id': 'pc-1',
            'pcClientName': 'ARC Desktop',
            'pairingId': 'pair-1',
            'credentialPresent': true,
            'gatewayUrl': 'https://api.licolite.app',
          },
        ],
      });

      expect(config.hasPairing, isTrue);
      expect(config.hasPairedDeviceEcho, isTrue);
      expect(config.deviceTabs.single.isUsable, isTrue);
    },
  );

  test(
    'load config synthesizes paired computer echo from pairing status payload',
    () async {
      final service = MobileRelayService();
      final agentService = AgentService(
        runCliExecutable: (executable, args, env) async {
          expect(args, [
            'mobile',
            'relay',
            'config',
            'get',
            '--authorize',
            'false',
            '--hydrate-secrets',
            'false',
          ]);
          return ProcessResult(
            0,
            0,
            jsonEncode({
              'ok': true,
              'config': {
                ..._configJson(pairingId: 'pair-1'),
                'paired': true,
                'mobileToken': '',
                'mobileTokenPresent': true,
              },
              'pairing': {
                'status': 'paired',
                'pc': {'clientId': 'pc-1', 'clientName': 'Mac Studio'},
              },
            }),
            '',
          );
        },
      );

      final config = await service.loadConfig(agentService: agentService);

      expect(config.deviceTabs, hasLength(1));
      expect(config.deviceTabs.single.id, 'pc-1');
      expect(config.deviceTabs.single.label, 'Mac Studio');
      expect(config.deviceTabs.single.credentialPresent, isTrue);
    },
  );

  test('paired computer echo ignores stale ephemeral gateway', () async {
    final service = MobileRelayService();
    final agentService = AgentService(
      runCliExecutable: (executable, args, env) async {
        return ProcessResult(
          0,
          0,
          jsonEncode({
            'ok': true,
            'gatewayUrl': 'https://old-relay.trycloudflare.com',
            'config': {
              ..._configJson(
                useCustomGateway: true,
                customGatewayUrl: 'https://old-relay.trycloudflare.com/',
                pairingId: 'pair-1',
              ),
              'paired': true,
              'mobileTokenPresent': true,
            },
            'pairing': {
              'status': 'paired',
              'pc': {'clientId': 'pc-1', 'clientName': 'Mac Studio'},
            },
          }),
          '',
        );
      },
    );

    final config = await service.loadConfig(agentService: agentService);

    expect(config.deviceTabs, hasLength(1));
    expect(
      config.deviceTabs.single.gatewayUrl,
      licoDefaultMobileRelayGatewayUrl,
    );
  });

  test('reset pairing delegates to config set resetPairing', () async {
    final captured = <List<String>>[];
    final service = MobileRelayService();
    final agentService = AgentService(
      runCliExecutable: (executable, args, env) async {
        captured.add(List<String>.from(args));
        return ProcessResult(
          0,
          0,
          jsonEncode({'ok': true, 'config': _configJson()}),
          '',
        );
      },
    );

    final config = await service.resetPairing(agentService: agentService);

    expect(config.hasPairing, isFalse);
    expect(captured.single, [
      'mobile',
      'relay',
      'config',
      'set',
      '--reset-pairing',
      'true',
    ]);
  });

  test(
    'delegates gateway, pairing, and sync operations to lico-client',
    () async {
      final captured = <List<String>>[];
      final agentService = AgentService(
        runCliExecutable: (executable, args, env) async {
          captured.add(List<String>.from(args));
          if (args.contains('create')) {
            return ProcessResult(
              0,
              0,
              jsonEncode({
                'ok': true,
                'pairingId': 'pair-1',
                'pairingCode': '1234-5678',
                'config': _configJson(
                  useCustomGateway: true,
                  customGatewayUrl: 'https://relay.example.test',
                  pairingId: 'pair-1',
                  pcToken: 'pc-token',
                  lastPairingCode: '',
                ),
              }),
              '',
            );
          }
          if (args.contains('sync')) {
            return ProcessResult(
              0,
              0,
              jsonEncode({
                'ok': true,
                'commands': [
                  {
                    'commandId': 'cmd-1',
                    'type': 'secure_mesh.envelope',
                    'payload': {},
                    'secureEnvelope': {
                      'protocolVersion': 'licolite.secure-mesh.v1',
                      'envelopeId': 'env-1',
                      'opaqueMailboxId': 'mailbox-1',
                      'messageId': 'msg-1',
                      'cipherSuite':
                          'licolite.pqxdh-triple-ratchet.v1.x25519-ed25519-mlkem1024-hkdfsha256-chacha20poly1305',
                      'createdAt': '2026-06-12T00:00:00Z',
                      'expiresAt': '2026-06-12T01:00:00Z',
                      'ciphertextSize': 32,
                      'encryptedHeader': 'header',
                      'ciphertext': 'ciphertext',
                    },
                    'status': 'in_progress',
                    'createdAt': '2026-06-12T00:00:00Z',
                  },
                ],
              }),
              '',
            );
          }
          if (args.length == 2 &&
              args[0] == 'secure-mesh' &&
              args[1] == 'status') {
            return ProcessResult(
              0,
              0,
              jsonEncode({
                'ok': true,
                'protocolVersion': 'licolite.secure-mesh.v1',
                'pairwiseCryptoStatus': 'pairwise-runtime-available',
                'cryptoCoreStatus': 'blocked_for_production',
              }),
              '',
            );
          }
          if (args.length >= 4 &&
              args[0] == 'secure-mesh' &&
              args[1] == 'command' &&
              args[2] == 'execute') {
            return ProcessResult(
              0,
              0,
              jsonEncode({
                'ok': true,
                'evaluation': {'accepted': true, 'shouldExecute': true},
                'execution': {'outcome': 'result'},
              }),
              '',
            );
          }
          if (args.length >= 4 &&
              args[0] == 'secure-mesh' &&
              args[1] == 'device-trust' &&
              args[2] == 'evaluate') {
            return ProcessResult(
              0,
              0,
              jsonEncode({
                'ok': true,
                'trustState': 'verified',
                'decision': {'code': 'trusted'},
              }),
              '',
            );
          }
          if (args.length >= 4 &&
              args[0] == 'secure-mesh' &&
              args[1] == 'file' &&
              args[2] == 'route') {
            return ProcessResult(
              0,
              0,
              jsonEncode({
                'ok': true,
                'route': {
                  'uploadOperation': 'secure_mesh.file_chunk.upload',
                  'fetchOperation': 'secure_mesh.file_chunk.fetch',
                },
              }),
              '',
            );
          }
          if (args.length >= 4 &&
              args[0] == 'secure-mesh' &&
              args[1] == 'file' &&
              args[2] == 'receive-destination') {
            return ProcessResult(
              0,
              0,
              jsonEncode({
                'ok': true,
                'receivePolicy': {
                  'destinationApproved': true,
                  'destinationPathRedacted': true,
                  'conflictPolicy': 'fail_if_exists',
                  'writeOperation': 'secure_mesh.file_receive.write',
                },
              }),
              '',
            );
          }
          if (args.length >= 4 &&
              args[0] == 'secure-mesh' &&
              args[1] == 'file' &&
              args[2] == 'receive-confirmation') {
            return ProcessResult(
              0,
              0,
              jsonEncode({
                'ok': true,
                'receiveConfirmation': {
                  'required': true,
                  'userVisibleConfirmationRequired': true,
                  'userConfirmed': args.contains('true'),
                  'writeAllowed': args.contains('true'),
                  'autoPreviewEnabled': false,
                  'autoIngestionEnabled': false,
                },
              }),
              '',
            );
          }
          return ProcessResult(
            0,
            0,
            jsonEncode({
              'ok': true,
              'config': _configJson(
                useCustomGateway: args.contains('true'),
                customGatewayUrl: 'https://relay.example.test',
              ),
            }),
            '',
          );
        },
      );
      const service = MobileRelayService();

      final config = await service.configureGateway(
        agentService: agentService,
        useCustomGateway: true,
        customGatewayUrl: 'https://relay.example.test/',
      );
      final response = await service.createPairing(agentService: agentService);
      final sync = await service.syncCommands(agentService: agentService);
      final status = await service.secureMeshStatus(agentService: agentService);
      final execution = await service.executeSecureMeshCommand(
        agentService: agentService,
        payload: const {
          'schema': 'licolite.secure-mesh.command.v1',
          'commandId': 'cmd-secure-1',
          'commandKind': 'client.activity.sync',
        },
        context: const {'localEndpointId': 'pc-b'},
        ledgerPath: '/tmp/secure-command-ledger.sqlite',
        completedAt: '2026-06-12T00:01:00Z',
      );
      final trustPolicy = await service.evaluateSecureMeshDeviceTrust(
        agentService: agentService,
        identity: const {
          'endpointId': 'pc-a',
          'identityPublicKey': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          'signingPublicKey': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
          'rotationEpoch': 1,
        },
        trustState: 'verified',
      );
      final fileRoute = await service.evaluateSecureMeshFileRoute(
        agentService: agentService,
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
      final receiveDestination = await service
          .evaluateSecureMeshFileReceiveDestination(
            agentService: agentService,
            manifest: const {
              'fileId': 'file-a',
              'fileName': 'launch-plan.pdf',
              'mimeType': 'application/pdf',
              'relativePath': 'workspace/reports',
              'totalSize': 16,
              'chunkSize': 8,
              'chunkCount': 2,
            },
            approvedRoot: '/tmp/approved-root',
          );
      final receiveConfirmation = await service
          .evaluateSecureMeshFileReceiveConfirmation(
            agentService: agentService,
            manifest: const {
              'fileId': 'file-a',
              'fileName': 'launch-plan.pdf',
              'mimeType': 'application/pdf',
              'relativePath': 'workspace/reports',
              'totalSize': 16,
              'chunkSize': 8,
              'chunkCount': 2,
            },
            approvedRoot: '/tmp/approved-root',
          );

      expect(config.effectiveGatewayUrl, 'https://relay.example.test');
      expect(response['pairingId'], 'pair-1');
      expect((sync['commands'] as List).single['commandId'], 'cmd-1');
      expect(status['protocolVersion'], 'licolite.secure-mesh.v1');
      expect(execution['ok'], isTrue);
      expect(trustPolicy['decision']['code'], 'trusted');
      expect(
        fileRoute['route']['uploadOperation'],
        'secure_mesh.file_chunk.upload',
      );
      expect(
        receiveDestination['receivePolicy']['writeOperation'],
        'secure_mesh.file_receive.write',
      );
      expect(
        receiveConfirmation['receiveConfirmation']['writeAllowed'],
        isFalse,
      );
      expect(
        receiveConfirmation['receiveConfirmation']['autoPreviewEnabled'],
        isFalse,
      );
      expect(captured[0], [
        'mobile',
        'relay',
        'config',
        'set',
        '--use-custom-gateway',
        'true',
        '--custom-gateway-url',
        'https://relay.example.test/',
      ]);
      expect(captured[1], ['mobile', 'relay', 'pairing', 'create']);
      expect(captured[2], [
        'mobile',
        'relay',
        'commands',
        'sync',
        '--allow-interaction',
        'true',
      ]);
      expect(captured[3], ['secure-mesh', 'status']);
      expect(captured[4], [
        'secure-mesh',
        'command',
        'execute',
        '--payload',
        jsonEncode({
          'schema': 'licolite.secure-mesh.command.v1',
          'commandId': 'cmd-secure-1',
          'commandKind': 'client.activity.sync',
        }),
        '--context',
        jsonEncode({'localEndpointId': 'pc-b'}),
        '--ledger-path',
        '/tmp/secure-command-ledger.sqlite',
        '--completed-at',
        '2026-06-12T00:01:00Z',
      ]);
      expect(captured[5], [
        'secure-mesh',
        'device-trust',
        'evaluate',
        '--identity',
        jsonEncode({
          'endpointId': 'pc-a',
          'identityPublicKey': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          'signingPublicKey': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
          'rotationEpoch': 1,
        }),
        '--trust-state',
        'verified',
        '--require-verified-device',
        'true',
        '--allow-unverified-read-only',
        'false',
      ]);
      expect(captured[6], [
        'secure-mesh',
        'file',
        'route',
        '--manifest',
        jsonEncode({
          'fileId': 'file-a',
          'fileName': 'launch-plan.pdf',
          'mimeType': 'application/pdf',
          'relativePath': 'workspace/reports',
          'totalSize': 16,
          'chunkSize': 8,
          'chunkCount': 2,
        }),
      ]);
      expect(captured[7], [
        'secure-mesh',
        'file',
        'receive-destination',
        '--manifest',
        jsonEncode({
          'fileId': 'file-a',
          'fileName': 'launch-plan.pdf',
          'mimeType': 'application/pdf',
          'relativePath': 'workspace/reports',
          'totalSize': 16,
          'chunkSize': 8,
          'chunkCount': 2,
        }),
        '--approved-root',
        '/tmp/approved-root',
        '--conflict-policy',
        'fail_if_exists',
      ]);
      expect(captured[8], [
        'secure-mesh',
        'file',
        'receive-confirmation',
        '--manifest',
        jsonEncode({
          'fileId': 'file-a',
          'fileName': 'launch-plan.pdf',
          'mimeType': 'application/pdf',
          'relativePath': 'workspace/reports',
          'totalSize': 16,
          'chunkSize': 8,
          'chunkCount': 2,
        }),
        '--approved-root',
        '/tmp/approved-root',
        '--user-confirmed',
        'false',
        '--conflict-policy',
        'fail_if_exists',
      ]);
    },
  );

  test('reads Android Secure Mesh runtime bridge status', () async {
    const channel = MethodChannel(secureMeshAndroidChannelName);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'writeRuntimeStatus') {
        return {
          'ok': true,
          'relativePath': 'files/secure-mesh/android-runtime-status.json',
          'writtenByAppProcess': true,
        };
      }
      expect(call.method, 'status');
      return {
        'ok': true,
        'protocolVersion': 'licolite.secure-mesh.v1',
        'endpointKind': 'mobile',
        'platform': 'android',
        'bridge': {
          'methodChannel': secureMeshAndroidChannelName,
          'statusMethod': true,
          'writeRuntimeStatusMethod': true,
        },
        'secureStore': {'provider': 'AndroidKeyStore', 'available': true},
        'runtimeStatusFile': {
          'relativePath': 'files/secure-mesh/android-runtime-status.json',
          'appPrivateFilesDir': true,
        },
        'productionReady': false,
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    const service = MobileRelayService();
    final status = await service.secureMeshAndroidRuntimeStatus(
      bridge: const SecureMeshAndroidBridge(channel: channel),
    );
    final written = await service.writeSecureMeshAndroidRuntimeStatus(
      bridge: const SecureMeshAndroidBridge(channel: channel),
    );

    expect(status['ok'], isTrue);
    expect(status['protocolVersion'], 'licolite.secure-mesh.v1');
    expect(status['bridge']['methodChannel'], secureMeshAndroidChannelName);
    expect(status['secureStore']['provider'], 'AndroidKeyStore');
    expect(
      status['runtimeStatusFile']['relativePath'],
      'files/secure-mesh/android-runtime-status.json',
    );
    expect(written['ok'], isTrue);
    expect(written['writtenByAppProcess'], isTrue);
    expect(calls, ['status', 'writeRuntimeStatus']);
    expect(status['productionReady'], isFalse);
  });

  test('secure relay poll accepts a validated runtime result', () {
    final polled = <String, dynamic>{
      'ok': true,
      'response': {
        'command': {'commandId': 'relay-command-canary', 'status': 'completed'},
      },
      'openedResult': {
        'execution': {
          'commandId': 'payload-command-canary',
          'idempotencyKey': 'idempotency-canary',
          'outcome': 'result',
          'output': {
            'ok': true,
            'commandKind': 'agent.message.send',
            'output': {'ok': true, 'content': 'relay-result-canary'},
          },
        },
      },
    };

    final completion = resolveSecureRelayPollResult(
      created: const {
        'ok': true,
        'command': {'commandId': 'relay-command-canary'},
        'secureCommandBinding': {
          'payloadCommandId': 'payload-command-canary',
          'idempotencyKey': 'idempotency-canary',
          'commandKind': 'agent.message.send',
        },
      },
      polled: polled,
    );

    expect(completion?['ok'], isTrue);
    expect(completion?['result'], same(polled));
  });

  test('secure relay poll rejects a result swapped across commands', () {
    final completion = resolveSecureRelayPollResult(
      created: const {
        'ok': true,
        'command': {'commandId': 'relay-command-expected'},
        'secureCommandBinding': {
          'payloadCommandId': 'payload-command-expected',
          'idempotencyKey': 'idempotency-expected',
          'commandKind': 'agent.message.send',
        },
      },
      polled: const {
        'ok': true,
        'response': {
          'command': {
            'commandId': 'relay-command-other',
            'status': 'completed',
          },
        },
        'openedResult': {
          'execution': {
            'commandId': 'payload-command-other',
            'idempotencyKey': 'idempotency-other',
            'outcome': 'result',
            'output': {
              'ok': true,
              'commandKind': 'agent.message.send',
              'output': {'ok': true},
            },
          },
        },
      },
    );

    expect(completion, const {
      'ok': false,
      'errorCode': 'secure_relay_command_binding_mismatch',
    });
  });

  test('secure relay poll returns only a redacted execution error code', () {
    final completion = resolveSecureRelayPollResult(
      created: const {
        'ok': true,
        'command': {'commandId': 'relay-command-canary'},
        'secureCommandBinding': {
          'payloadCommandId': 'payload-command-canary',
          'idempotencyKey': 'idempotency-canary',
          'commandKind': 'agent.message.send',
        },
      },
      polled: const {
        'ok': true,
        'response': {
          'command': {'commandId': 'relay-command-canary', 'status': 'failed'},
        },
        'openedResult': {
          'execution': {
            'commandId': 'payload-command-canary',
            'idempotencyKey': 'idempotency-canary',
            'outcome': 'error',
            'errorCode': 'command_replay_rejected',
            'errorDetail': 'private-error-detail-canary',
          },
        },
      },
    );

    expect(completion, const {
      'ok': false,
      'errorCode': 'command_replay_rejected',
    });
    expect(
      jsonEncode(completion),
      isNot(contains('private-error-detail-canary')),
    );
  });

  test('secure relay poll fails closed when nested runtime output fails', () {
    final completion = resolveSecureRelayPollResult(
      created: const {
        'ok': true,
        'command': {'commandId': 'relay-command-canary'},
        'secureCommandBinding': {
          'payloadCommandId': 'payload-command-canary',
          'idempotencyKey': 'idempotency-canary',
          'commandKind': 'agent.message.send',
        },
      },
      polled: const {
        'ok': true,
        'response': {
          'command': {
            'commandId': 'relay-command-canary',
            'status': 'completed',
          },
        },
        'openedResult': {
          'execution': {
            'commandId': 'payload-command-canary',
            'idempotencyKey': 'idempotency-canary',
            'outcome': 'result',
            'output': {
              'ok': true,
              'commandKind': 'agent.message.send',
              'output': {
                'ok': false,
                'errorCode': 'unsafe error detail',
                'error': 'private-runtime-detail-canary',
              },
            },
          },
        },
      },
    );

    expect(completion, const {
      'ok': false,
      'errorCode': 'secure_relay_runtime_failed',
    });
    expect(
      jsonEncode(completion),
      isNot(contains('private-runtime-detail-canary')),
    );
  });

  test('secure relay poll rejects malformed opened result structure', () {
    const malformedOpenedResults = <Map<String, dynamic>>[
      {'unexpected': true},
      {
        'execution': {
          'commandId': 'payload-command-canary',
          'idempotencyKey': 'idempotency-canary',
          'outcome': 'result',
        },
      },
      {
        'execution': {
          'commandId': 'payload-command-canary',
          'idempotencyKey': 'idempotency-canary',
          'outcome': 'result',
          'output': {'ok': true},
        },
      },
      {
        'execution': {
          'commandId': 'payload-command-canary',
          'idempotencyKey': 'idempotency-canary',
          'outcome': 'result',
          'output': {
            'ok': true,
            'commandKind': 'agent.message.send',
            'output': {'content': 'missing-ok-must-not-pass'},
          },
        },
      },
    ];

    for (final openedResult in malformedOpenedResults) {
      final completion = resolveSecureRelayPollResult(
        created: const {
          'ok': true,
          'command': {'commandId': 'relay-command-canary'},
          'secureCommandBinding': {
            'payloadCommandId': 'payload-command-canary',
            'idempotencyKey': 'idempotency-canary',
            'commandKind': 'agent.message.send',
          },
        },
        polled: {
          'ok': true,
          'response': {
            'command': {
              'commandId': 'relay-command-canary',
              'status': 'completed',
            },
          },
          'openedResult': openedResult,
        },
      );

      expect(completion, const {
        'ok': false,
        'errorCode': 'secure_relay_result_invalid',
      });
    }
  });

  test('secure agent session list extracts exact native projections', () {
    final resolved = resolveSecureAgentSessionListResult(
      agentId: 'codex',
      result: {
        'ok': true,
        'result': {
          'openedResult': {
            'execution': {
              'outcome': 'result',
              'output': {
                'ok': true,
                'commandKind': 'agent.sessions.list',
                'output': {
                  'ok': true,
                  'mode': 'native-history',
                  'importMode': 'precise-adapter',
                  'readOnly': true,
                  'agentId': 'codex',
                  'sessions': [
                    {
                      'id': 'codex-projection-1',
                      'nativeSessionId': 'codex-native-thread-1',
                      'agentId': 'codex',
                      'adapterId': 'codex',
                      'native': true,
                      'readOnly': true,
                      'title': 'Native session',
                      'createdAt': '2026-07-10T00:00:00Z',
                      'updatedAt': '2026-07-10T00:00:01Z',
                      'sourcePath': [
                        '',
                        'private',
                        'native',
                        'history.jsonl',
                      ].join('/'),
                      'workingDirectory': [
                        '',
                        'private',
                        'native',
                        'workspace',
                      ].join('/'),
                      'messages': [
                        {
                          'id': 'tool-message-1',
                          'role': 'tool',
                          'text': 'Tool call details are hidden.',
                          'createdAt': '2026-07-10T00:00:01Z',
                          'cardType': 'tool_call',
                          'cardTitle': 'Tool call',
                          'cardSubtitle': 'redacted',
                          'collapsed': false,
                          'arguments': {
                            'path': [
                              '',
                              'private',
                              'native',
                              'workspace',
                              'secret.txt',
                            ].join('/'),
                          },
                          'messages': [
                            {
                              'id': 'reasoning-child-1',
                              'role': 'reasoning',
                              'text': 'Reasoning content is hidden.',
                              'createdAt': '2026-07-10T00:00:01Z',
                              'cardType': 'reasoning',
                              'cardTitle': 'Reasoning',
                              'collapsed': true,
                              'metadata': {
                                'token': [
                                  'private',
                                  'token',
                                  'canary',
                                ].join('-'),
                              },
                            },
                          ],
                        },
                      ],
                    },
                  ],
                  'page': {'hasMore': false},
                },
              },
            },
          },
        },
      },
    );

    expect(resolved['ok'], isTrue);
    expect(resolved['agentId'], 'codex');
    expect(resolved['hasMore'], isFalse);
    final sessions = resolved['sessions'] as List;
    expect(sessions, hasLength(1));
    expect(sessions.single['id'], 'codex-projection-1');
    expect(sessions.single['nativeSessionId'], 'codex-native-thread-1');
    expect(sessions.single, isNot(contains('sourcePath')));
    expect(sessions.single, isNot(contains('workingDirectory')));
    final messages = sessions.single['messages'] as List;
    expect(messages.single['cardType'], 'tool_call');
    expect(messages.single['cardTitle'], 'Tool call');
    expect(messages.single['collapsed'], isFalse);
    expect(messages.single, isNot(contains('arguments')));
    final children = messages.single['messages'] as List;
    expect(children.single['cardType'], 'reasoning');
    expect(children.single, isNot(contains('metadata')));
    expect(jsonEncode(sessions), isNot(contains('private-token-canary')));
    expect(
      jsonEncode(sessions),
      isNot(contains(['', 'private', 'native'].join('/'))),
    );
  });

  test(
    'secure agent session list deterministically reduces native duplicates',
    () {
      final resolved = resolveSecureAgentSessionListResult(
        agentId: 'codex',
        result: _secureAgentSessionListRelayResult([
          _secureAgentSessionFixture(
            id: 'archive-projection',
            nativeSessionId: 'shared-native-thread',
            updatedAt: '2026-07-10T00:00:01Z',
            text: 'Archived conversation copy',
            sourcePath: ['', 'private', 'archive', 'history.jsonl'].join('/'),
          ),
          _secureAgentSessionFixture(
            id: 'active-projection',
            nativeSessionId: 'shared-native-thread',
            updatedAt: '2026-07-10T00:00:02Z',
            text: 'Current conversation copy',
            sourcePath: ['', 'private', 'active', 'history.jsonl'].join('/'),
          ),
        ]),
      );

      expect(resolved['ok'], isTrue);
      final sessions = resolved['sessions'] as List;
      expect(sessions, hasLength(1));
      expect(sessions.single['id'], 'active-projection');
      expect(sessions.single['nativeSessionId'], 'shared-native-thread');
      expect(sessions.single['sourcePath'], isNull);
      expect(
        sessions.single['messages'].single['text'],
        'Current conversation copy',
      );
    },
  );

  test('secure agent session list rejects oversized decrypted history', () {
    final oversizedText = List<String>.filled(
      2 * 1024 * 1024,
      'x',
      growable: false,
    ).join();
    final resolved = resolveSecureAgentSessionListResult(
      agentId: 'codex',
      result: _secureAgentSessionListRelayResult([
        _secureAgentSessionFixture(
          id: 'oversized-projection',
          nativeSessionId: 'oversized-native-thread',
          updatedAt: '2026-07-10T00:00:01Z',
          text: oversizedText,
        ),
      ]),
    );

    expect(resolved, const {
      'ok': false,
      'errorCode': 'secure_agent_sessions_payload_too_large',
    });
  });

  test('secure agent session list fails closed without native continuity', () {
    final resolved = resolveSecureAgentSessionListResult(
      agentId: 'codex',
      result: const {
        'ok': true,
        'result': {
          'openedResult': {
            'execution': {
              'outcome': 'result',
              'output': {
                'ok': true,
                'commandKind': 'agent.sessions.list',
                'output': {
                  'ok': true,
                  'mode': 'native-history',
                  'importMode': 'precise-adapter',
                  'readOnly': true,
                  'agentId': 'codex',
                  'sessions': [
                    {
                      'id': 'projection-without-native-id',
                      'nativeSessionId': '',
                      'agentId': 'codex',
                      'native': true,
                      'readOnly': true,
                    },
                  ],
                  'page': {'hasMore': false},
                },
              },
            },
          },
        },
      },
    );

    expect(resolved, const {
      'ok': false,
      'errorCode': 'secure_agent_sessions_result_invalid',
    });
  });

  test('secure agent session list redacts an unsafe relay failure', () {
    final resolved = resolveSecureAgentSessionListResult(
      agentId: 'codex',
      result: const {
        'ok': false,
        'errorCode': 'unsafe private error detail',
        'error': 'private-session-history-canary',
      },
    );

    expect(resolved, const {
      'ok': false,
      'errorCode': 'secure_agent_sessions_list_failed',
    });
    expect(jsonEncode(resolved), isNot(contains('private-session-history')));
  });

  test('secure agent session describe extracts an exact native projection', () {
    final resolved = resolveSecureAgentSessionListResult(
      agentId: 'codex',
      commandKind: 'agent.sessions.describe',
      result: _secureAgentSessionListRelayResult(
        [
          _secureAgentSessionFixture(
            id: 'codex-projection-exact',
            nativeSessionId: 'codex-native-exact',
            updatedAt: '2026-07-10T00:00:01Z',
            text: 'Exact older conversation',
          ),
        ],
        commandKind: 'agent.sessions.describe',
        hasMore: false,
      ),
    );

    expect(resolved['ok'], isTrue);
    expect(resolved['hasMore'], isFalse);
    final sessions = resolved['sessions'] as List;
    expect(sessions, hasLength(1));
    expect(sessions.single['nativeSessionId'], 'codex-native-exact');
  });

  test('secure agent session list preserves hasMore paging signal', () {
    final resolved = resolveSecureAgentSessionListResult(
      agentId: 'codex',
      result: _secureAgentSessionListRelayResult([
        _secureAgentSessionFixture(
          id: 'codex-projection-page',
          nativeSessionId: 'codex-native-page',
          updatedAt: '2026-07-10T00:00:01Z',
          text: 'Paged conversation',
        ),
      ], hasMore: true),
    );

    expect(resolved['ok'], isTrue);
    expect(resolved['hasMore'], isTrue);
  });

  test('reads iOS Secure Mesh runtime bridge status and native JSON', () async {
    const channel = MethodChannel(secureMeshIosChannelName);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'nativeJson') {
        final request = Map<String, dynamic>.from(call.arguments as Map);
        return {'ok': true, 'action': request['action'], 'platform': 'ios'};
      }
      expect(call.method, 'status');
      return {
        'ok': true,
        'protocolVersion': 'licolite.secure-mesh.v1',
        'endpointKind': 'mobile',
        'platform': 'ios',
        'bridge': {
          'methodChannel': secureMeshIosChannelName,
          'statusMethod': true,
          'nativeJsonMethod': true,
        },
        'secureStore': {'provider': 'iOS Keychain', 'available': true},
        'nativeRuntime': {'usesSharedRustCore': true},
        'productionReady': false,
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    const bridge = SecureMeshIosBridge(channel: channel);
    final status = await bridge.status();
    final native = await bridge.nativeJson({
      'action': 'mobile.relay.e2ee.status',
      'params': const {},
    });

    expect(status['ok'], isTrue);
    expect(status['platform'], 'ios');
    expect(status['bridge']['methodChannel'], secureMeshIosChannelName);
    expect(status['secureStore']['provider'], 'iOS Keychain');
    expect(status['nativeRuntime']['usesSharedRustCore'], isTrue);
    expect(native['ok'], isTrue);
    expect(native['action'], 'mobile.relay.e2ee.status');
    expect(native['platform'], 'ios');
    expect(calls, ['status', 'nativeJson']);
  });
}

Map<String, dynamic> _secureAgentSessionListRelayResult(
  List<Map<String, dynamic>> sessions, {
  String commandKind = 'agent.sessions.list',
  bool hasMore = false,
}) {
  return {
    'ok': true,
    'result': {
      'openedResult': {
        'execution': {
          'outcome': 'result',
          'output': {
            'ok': true,
            'commandKind': commandKind,
            'output': {
              'ok': true,
              'mode': 'native-history',
              'importMode': 'precise-adapter',
              'readOnly': true,
              'agentId': 'codex',
              'sessions': sessions,
              'page': {'hasMore': hasMore},
            },
          },
        },
      },
    },
  };
}

Map<String, dynamic> _secureAgentSessionFixture({
  required String id,
  required String nativeSessionId,
  required String updatedAt,
  required String text,
  String sourcePath = '',
}) {
  return {
    'id': id,
    'nativeSessionId': nativeSessionId,
    'agentId': 'codex',
    'adapterId': 'codex',
    'native': true,
    'readOnly': true,
    'title': text.isEmpty ? 'Native session' : text.substring(0, 1),
    'createdAt': '2026-07-10T00:00:00Z',
    'updatedAt': updatedAt,
    if (sourcePath.isNotEmpty) 'sourcePath': sourcePath,
    'workingDirectory': ['', 'private', 'native', 'workspace'].join('/'),
    'messages': [
      {
        'id': '$id-message',
        'role': 'assistant',
        'text': text,
        'createdAt': updatedAt,
      },
    ],
  };
}

Map<String, dynamic> _configJson({
  bool useCustomGateway = false,
  String customGatewayUrl = '',
  String pairingId = '',
  String pcToken = '',
  String lastPairingCode = '',
  String lastPairingExpiresAt = '',
}) {
  return {
    'schemaVersion': 1,
    'defaultGatewayUrl': licoDefaultMobileRelayGatewayUrl,
    'useCustomGateway': useCustomGateway,
    'customGatewayUrl': customGatewayUrl,
    'pcClientId': 'pc-test',
    'pcClientName': 'Test PC',
    'pairingId': pairingId,
    'pcToken': pcToken,
    'lastPairingCode': lastPairingCode,
    'lastPairingExpiresAt': lastPairingExpiresAt,
    'paired': false,
    'relayEnabled': false,
    'pollIntervalSeconds': 5,
  };
}
