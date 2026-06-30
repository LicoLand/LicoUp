import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_client/src/services/agent_service.dart';
import 'package:flutter_client/src/services/mobile_relay_service.dart';
import 'package:flutter_client/src/services/secure_mesh_android_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
                  lastPairingCode: '1234-5678',
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
                      'cipherSuite': 'licolite.signal-x3dh-dr.v1.classical',
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
      expect(captured[2], ['mobile', 'relay', 'commands', 'sync']);
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
}

Map<String, dynamic> _configJson({
  bool useCustomGateway = false,
  String customGatewayUrl = '',
  String pairingId = '',
  String pcToken = '',
  String lastPairingCode = '',
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
    'lastPairingExpiresAt': '2026-06-12T12:00:00Z',
    'paired': false,
    'relayEnabled': false,
    'pollIntervalSeconds': 5,
  };
}
