import 'package:licoup/src/contracts/mobile_relay/mobile_relay_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('canonicalizes HTTPS and exact loopback HTTP station origins', () {
    expect(
      canonicalMobileRelayStationOrigin('HTTPS://Station.Example.Test:443/'),
      'https://station.example.test',
    );
    expect(
      canonicalMobileRelayStationOrigin('http://127.0.0.1:7228/'),
      'http://127.0.0.1:7228',
    );
    expect(
      canonicalMobileRelayStationOrigin('http://localhost:7228'),
      'http://localhost:7228',
    );
    expect(
      canonicalMobileRelayStationOrigin('http://[::1]:7228/'),
      'http://[::1]:7228',
    );
  });

  test('rejects malformed deceptive and non-origin station values', () {
    for (final denied in const [
      'https://',
      'https://?station=station.example.test',
      'https:///station.example.test',
      'https://user@station.example.test',
      'https://user:password@station.example.test',
      'https://station.example.test#fragment',
      'https://station.example.test:invalid',
      'https://station.example.test:0',
      'https://station.example.test/api',
      'https://station.example.test?tenant=one',
      'https://station.example.test\\@evil.test',
      'http://example.test',
      'http://localhost.evil.test',
      'http://127.0.0.1@evil.test',
      'http://127.0.0.2',
      'http://127.1',
    ]) {
      expect(
        canonicalMobileRelayStationOrigin(denied),
        isNull,
        reason: 'accepted $denied',
      );
    }
  });

  test('client config fails closed on an invalid native station echo', () {
    final config = MobileRelayConfig.fromJson(const {
      'stationBaseUrl': 'https://trusted.example@evil.test#fragment',
      'pairedDevices': [
        {
          'id': 'device-a',
          'pairingId': 'pair-a',
          'credentialPresent': true,
          'stationBaseUrl': 'https://trusted.example@evil.test#fragment',
        },
      ],
    });

    expect(config.stationBaseUrl, isEmpty);
    expect(config.pairedDevices.single.stationBaseUrl, isEmpty);
  });
}
