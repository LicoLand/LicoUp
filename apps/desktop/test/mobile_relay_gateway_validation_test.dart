import 'package:flutter_client/src/contracts/mobile_relay/mobile_relay_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('canonicalizes HTTPS and exact loopback HTTP gateway origins', () {
    expect(
      canonicalMobileRelayGatewayOrigin('HTTPS://Relay.Example.Test:443/'),
      'https://relay.example.test',
    );
    expect(
      canonicalMobileRelayGatewayOrigin('http://127.0.0.1:7228/'),
      'http://127.0.0.1:7228',
    );
    expect(
      canonicalMobileRelayGatewayOrigin('http://localhost:7228'),
      'http://localhost:7228',
    );
    expect(
      canonicalMobileRelayGatewayOrigin('http://[::1]:7228/'),
      'http://[::1]:7228',
    );
  });

  test('rejects malformed deceptive and non-origin gateway values', () {
    for (final denied in const [
      'https://',
      'https://?gateway=relay.example.test',
      'https:///relay.example.test',
      'https://user@relay.example.test',
      'https://user:password@relay.example.test',
      'https://relay.example.test#fragment',
      'https://relay.example.test:invalid',
      'https://relay.example.test:0',
      'https://relay.example.test/api',
      'https://relay.example.test?tenant=one',
      'https://relay.example.test\\@evil.test',
      'http://example.test',
      'http://localhost.evil.test',
      'http://127.0.0.1@evil.test',
      'http://127.0.0.2',
      'http://127.1',
    ]) {
      expect(
        canonicalMobileRelayGatewayOrigin(denied),
        isNull,
        reason: 'accepted $denied',
      );
    }
  });

  test('client config fails closed on an invalid native gateway echo', () {
    final config = MobileRelayConfig.fromJson(const {
      'defaultGatewayUrl': '',
      'useCustomGateway': true,
      'customGatewayUrl': 'https://trusted.example@evil.test#fragment',
      'pairedDevices': [
        {
          'id': 'device-a',
          'pairingId': 'pair-a',
          'credentialPresent': true,
          'gatewayUrl': 'https://trusted.example@evil.test#fragment',
        },
      ],
    });

    expect(config.useCustomGateway, isFalse);
    expect(config.customGatewayUrl, isEmpty);
    expect(config.effectiveGatewayUrl, isEmpty);
    expect(config.pairedDevices.single.gatewayUrl, isEmpty);
  });
}
