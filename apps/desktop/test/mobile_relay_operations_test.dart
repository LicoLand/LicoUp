import 'package:licoup/src/contracts/mobile_relay/mobile_relay_models.dart';
import 'package:licoup/src/platform/mobile_relay/mobile_relay_native_dispatch.dart';
import 'package:licoup/src/platform/mobile_relay/mobile_relay_service_ops.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_mobile_relay_dispatch.dart';

void main() {
  test('ordinary desktop config uses the narrow CLI dispatch port', () async {
    final dispatch = FakeMobileRelayDispatch(
      cliResult: const {
        'config': {
          'stationBaseUrl': 'https://station.example.test',
          'pcClientId': 'desktop-client',
          'pcClientName': 'Desktop',
        },
      },
    );
    final operations = MobileRelayOperations(dispatch: dispatch);

    final config = await operations.loadConfig(
      agentService: FakeAgentCommandRunner(),
    );

    expect(dispatch.cliCalls, [
      [
        'mobile',
        'relay',
        'config',
        'get',
        '--authorize',
        'false',
        '--hydrate-secrets',
        'false',
      ],
    ]);
    expect(config.pcClientId, 'desktop-client');
    expect(config.pcClientName, 'Desktop');
  });

  test('ordinary mobile config uses the native bridge dispatch port', () async {
    final dispatch = FakeMobileRelayDispatch(
      isAndroid: true,
      mobileResult: const {
        'config': {'stationBaseUrl': 'https://station.example.test'},
      },
    );
    final operations = MobileRelayOperations(dispatch: dispatch);

    await operations.loadConfig(
      agentService: FakeAgentCommandRunner(),
      authorizeSecrets: true,
    );

    expect(dispatch.cliCalls, isEmpty);
    expect(dispatch.mobileCalls, hasLength(1));
    expect(dispatch.mobileCalls.single.action, 'mobile.relay.config.get');
    expect(dispatch.mobileCalls.single.authorize, isTrue);
    expect(dispatch.mobileCalls.single.params, {
      'authorize': true,
      'hydrateSecrets': true,
    });
  });

  test('desktop private relay inputs never enter CLI arguments', () async {
    final dispatch = FakeMobileRelayDispatch();
    final operations = MobileRelayOperations(dispatch: dispatch);
    final runner = FakeAgentCommandRunner();

    await operations.saveConfig(
      agentService: runner,
      config: const MobileRelayConfig(
        schemaVersion: MobileRelayConfig.currentSchemaVersion,
        stationBaseUrl: 'https://station.example.test',
        pcClientId: 'synthetic-client',
        pcClientName: 'Synthetic Client',
        pairingId: 'synthetic-pairing',
        pcToken: '',
        mobileToken: 'synthetic-private-token',
        lastPairingCode: '',
        lastPairingExpiresAt: '',
        paired: true,
        relayEnabled: true,
        pollIntervalSeconds: 5,
        pcTokenPresent: false,
        mobileTokenPresent: true,
      ),
    );
    await operations.claimPairing(
      agentService: runner,
      invite: const {'pairingSecret': 'synthetic-private-secret'},
    );

    expect(dispatch.cliCalls, isEmpty);
    expect(dispatch.privateCliCalls, hasLength(2));
    expect(
      dispatch.privateCliCalls.expand((call) => call.arguments),
      isNot(contains('synthetic-private-token')),
    );
    expect(
      dispatch.privateCliCalls.expand((call) => call.arguments),
      isNot(contains('synthetic-private-secret')),
    );
    expect(
      dispatch.privateCliCalls.first.params['mobileToken'],
      'synthetic-private-token',
    );
    expect(
      dispatch.privateCliCalls.first.params['stationBaseUrl'],
      'https://station.example.test',
    );
    expect(
      (dispatch.privateCliCalls.last.params['invite'] as Map)['pairingSecret'],
      'synthetic-private-secret',
    );
  });

  test('external URL validation prevents non-HTTPS native dispatch', () async {
    final dispatch = FakeMobileRelayDispatch();
    final operations = MobileRelayOperations(dispatch: dispatch);
    final runner = FakeAgentCommandRunner();

    final rejected = await operations.openExternalUrl(
      agentService: runner,
      url: 'http://example.invalid',
    );
    final opened = await operations.openExternalUrl(
      agentService: runner,
      url: 'https://example.invalid/path',
    );

    expect(rejected['status'], 'unsupported_url');
    expect(opened['status'], 'opened');
    expect(dispatch.externalCalls, [Uri.parse('https://example.invalid/path')]);
  });

  test(
    'default dispatch replaces unknown native errors with a fixed code',
    () async {
      const dispatch = DefaultMobileRelayNativeDispatch();
      final runner = FakeAgentCommandRunner(
        onRunCli: (arguments) => throw StateError('raw native detail'),
      );

      try {
        await dispatch.runCli(runner, const [
          'mobile',
          'relay',
          'config',
          'get',
        ]);
        fail('expected MobileRelayDispatchException');
      } on MobileRelayDispatchException catch (error) {
        expect(error.code, 'native_command_failed');
        expect(error.toString(), isNot(contains('raw native detail')));
      }
    },
  );
}
