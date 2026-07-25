import 'dart:convert';
import 'dart:io';

import 'package:licoup/src/platform/mobile_relay/mobile_relay_service.dart';
import 'package:licoup/src/platform/native_client/agent_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'config_fixtures.dart';

void registerMobileRelayPairingScenarios() {
  test(
    'device tabs collapse stale duplicate pairings for the same computer',
    () {
      final config = MobileRelayConfig.fromJson(const {
        'pairedDevices': [
          {
            'id': 'old-pc',
            'pcClientName': 'LicoUp',
            'pairingId': 'pair-old',
            'credentialPresent': true,
            'gatewayUrl': 'https://relay.example.test',
          },
          {
            'id': 'new-pc',
            'pcClientName': 'LicoUp',
            'pairingId': 'pair-new',
            'credentialPresent': true,
            'gatewayUrl': 'https://relay.example.test/',
          },
        ],
      });

      expect(config.deviceTabs, hasLength(1));
      expect(config.deviceTabs.single.pairingId, 'pair-new');
      expect(config.deviceTabs.single.label, 'LicoUp');
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
        'schemaVersion': 'licomesh.secure-mesh.device-trust-presentation.v1',
        'protocolVersion': 'licomesh.secure-mesh.device-trust.v2',
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
        'qrPayload': 'licomesh-trust-qr',
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
            'gatewayUrl': 'https://relay.example.test',
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
                ...mobileRelayConfigJson(pairingId: 'pair-1'),
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
              ...mobileRelayConfigJson(
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
    expect(config.deviceTabs.single.gatewayUrl, 'https://relay.example.test');
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
          jsonEncode({'ok': true, 'config': mobileRelayConfigJson()}),
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

  test('delegates gateway, pairing, and sync operations to licoup', () async {
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
              'config': mobileRelayConfigJson(
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
                    'protocolVersion': 'licomesh.secure-mesh.v1',
                    'envelopeId': 'env-1',
                    'opaqueMailboxId': 'mailbox-1',
                    'messageId': 'msg-1',
                    'cipherSuite':
                        'licomesh.pqxdh-triple-ratchet.v1.x25519-ed25519-mlkem1024-hkdfsha256-chacha20poly1305',
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
              'protocolVersion': 'licomesh.secure-mesh.v1',
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
            'config': mobileRelayConfigJson(
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
        'schema': 'licomesh.secure-mesh.command.v1',
        'commandId': 'cmd-secure-1',
        'commandKind': 'client.activity.sync',
      },
      context: const {'localEndpointId': 'pc-b'},
      ledgerPath: 'test-data/secure-command-ledger.sqlite',
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
          approvedRoot: 'test-data/approved-root',
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
          approvedRoot: 'test-data/approved-root',
        );

    expect(config.effectiveGatewayUrl, 'https://relay.example.test');
    expect(response['pairingId'], 'pair-1');
    expect((sync['commands'] as List).single['commandId'], 'cmd-1');
    expect(status['protocolVersion'], 'licomesh.secure-mesh.v1');
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
    expect(receiveConfirmation['receiveConfirmation']['writeAllowed'], isFalse);
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
        'schema': 'licomesh.secure-mesh.command.v1',
        'commandId': 'cmd-secure-1',
        'commandKind': 'client.activity.sync',
      }),
      '--context',
      jsonEncode({'localEndpointId': 'pc-b'}),
      '--ledger-path',
      'test-data/secure-command-ledger.sqlite',
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
      'test-data/approved-root',
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
      'test-data/approved-root',
      '--user-confirmed',
      'false',
      '--conflict-policy',
      'fail_if_exists',
    ]);
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  registerMobileRelayPairingScenarios();
}
