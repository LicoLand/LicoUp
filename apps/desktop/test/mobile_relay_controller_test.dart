import 'package:licoup/src/application/features/mobile_relay/controller/mobile_relay_controller.dart';
import 'package:licoup/src/contracts/mobile_relay/mobile_relay_models.dart';
import 'package:licoup/src/contracts/mobile_relay_control.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'pairing keeps credentials private and exposes a bounded presentation',
    () async {
      final client = _FakeMobileRelayClient();
      final statuses = <MobileRelayFeatureStatus>[];
      var targetScans = 0;
      final controller = MobileRelayController(
        client: client,
        operationGate: MobileRelayOperationGate(),
        isMobileRuntime: () => false,
        isAndroid: () => true,
        isIos: () => false,
        writeClipboard: (_) async {},
        onStatus: statuses.add,
        ensureTargets: () async => targetScans += 1,
        discoverTargets: (_) async {},
      );
      addTearDown(controller.dispose);
      controller.replaceConfig(client.config);

      await controller.createPairing();

      expect(controller.pairingPresentation?.pairingCode, 'SAFE-CODE');
      expect(
        controller.pairingPresentation?.inviteText,
        startsWith('licoup://'),
      );
      expect(
        controller.actionResult,
        isNot(contains('mobileRelayPairingInvite')),
      );
      expect(
        controller.actionResult.toString(),
        isNot(contains('secret-value')),
      );
      expect(controller.config.pcToken, isEmpty);
      expect(controller.config.pcTokenPresent, isTrue);
      expect(targetScans, 1);
      expect(statuses.last.errorCode, isEmpty);

      controller.dismissPairingPresentation();
      expect(controller.pairingPresentation, isNull);
    },
  );

  test(
    'polling projects commands without payloads or raw execution output',
    () async {
      final client = _FakeMobileRelayClient();
      final controller = MobileRelayController(
        client: client,
        operationGate: MobileRelayOperationGate(),
        isMobileRuntime: () => false,
        isAndroid: () => true,
        isIos: () => false,
        writeClipboard: (_) async {},
        onStatus: (_) {},
        ensureTargets: () async {},
        discoverTargets: (_) async {},
      );
      addTearDown(controller.dispose);
      controller.replaceConfig(client.config);

      await controller.pollOnce(showProgress: true);

      expect(controller.commands, hasLength(1));
      expect(controller.commands.single.payload, isEmpty);
      expect(controller.secureExecutions, [
        {'commandId': 'command-1', 'ok': true},
      ]);
      expect(controller.actionResult?['commandCount'], 1);
      expect(
        controller.actionResult.toString(),
        isNot(contains('secret-value')),
      );
    },
  );

  test(
    'pairing fails closed until a station is explicitly configured',
    () async {
      final client = _FakeMobileRelayClient()
        ..config = MobileRelayConfig.defaults();
      final statuses = <MobileRelayFeatureStatus>[];
      final controller = MobileRelayController(
        client: client,
        operationGate: MobileRelayOperationGate(),
        isMobileRuntime: () => false,
        isAndroid: () => false,
        isIos: () => false,
        writeClipboard: (_) async {},
        onStatus: statuses.add,
        ensureTargets: () async {},
        discoverTargets: (_) async {},
      );
      addTearDown(controller.dispose);

      await controller.createPairing();

      expect(client.createPairingCalls, 0);
      expect(statuses.last.errorCode, 'mobile_relay_station_required');
    },
  );
}

final class _FakeMobileRelayClient implements MobileRelayClient {
  int createPairingCalls = 0;
  MobileRelayConfig config = MobileRelayConfig.defaults().copyWith(
    stationBaseUrl: 'https://station.example.test',
    pairingId: 'pairing-1',
    pcToken: 'secret-value',
    pcTokenPresent: true,
    paired: true,
  );

  @override
  Future<MobileRelayConfig> loadConfig({bool authorizeSecrets = false}) async =>
      config;

  @override
  Future<void> saveConfig(MobileRelayConfig value) async {
    config = value;
  }

  @override
  Future<MobileRelayConfig> configureStation({
    required String stationBaseUrl,
  }) async => config;

  @override
  Future<Map<String, dynamic>> createPairing() async {
    createPairingCalls += 1;
    return {
      'ok': true,
      'pairingCode': 'SAFE-CODE',
      'mobileRelayPairingInvite': {
        'stationBaseUrl': 'https://station.example.test',
        'pairingCode': 'SAFE-CODE',
        'pairingId': 'pairing-1',
        'e2eePairingSecret': 'secret-value',
      },
    };
  }

  @override
  Future<Map<String, dynamic>> refreshPairingStatus() async => const {
    'ok': true,
  };

  @override
  Future<Map<String, dynamic>> claimPairing(
    Map<String, dynamic> invite,
  ) async => const {'ok': true};

  @override
  Future<Map<String, dynamic>> syncCommands({
    required bool allowInteraction,
  }) async => {
    'ok': true,
    'commands': [
      {
        'commandId': 'command-1',
        'type': 'secure_mesh.command',
        'status': 'pending',
        'createdAt': '2026-01-01T00:00:00Z',
        'payload': {
          'secureCommandPayload': {'content': 'secret-value'},
          'secureCommandContext': {'scope': 'test'},
        },
      },
    ],
  };

  @override
  Future<Map<String, dynamic>> executeSecureMeshCommand({
    required Map<String, dynamic> payload,
    required Map<String, dynamic> context,
  }) async => const {'ok': true, 'rawOutput': 'secret-value'};
}
