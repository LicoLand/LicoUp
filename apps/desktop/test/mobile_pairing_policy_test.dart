import 'package:licoup/src/application/features/mobile_relay/policy/mobile_pairing_invite_codec.dart';
import 'package:licoup/src/application/features/mobile_relay/policy/mobile_pairing_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const invite = <String, dynamic>{
    'pairingId': 'pair-1',
    'pairingCode': '1234-5678',
    'e2eePairingSecret': 'one-time-secret',
  };

  test('codec round-trips direct, token, and link forms', () {
    final link = MobilePairingInviteCodec.encodeLink(invite);

    expect(MobilePairingInviteCodec.decode(link), invite);
    expect(
      MobilePairingInviteCodec.decode(
        Uri.parse(link).queryParameters['invite']!,
      ),
      invite,
    );
    expect(
      MobilePairingInviteCodec.decode(
        '{"pairingId":"pair-1","pairingCode":"1234-5678"}',
      ),
      containsPair('pairingId', 'pair-1'),
    );
  });

  test('codec rejects malformed and oversized invitations', () {
    expect(
      () => MobilePairingInviteCodec.decode('not-an-invite'),
      throwsFormatException,
    );
    expect(
      () => MobilePairingInviteCodec.decode('x' * (128 * 1024 + 1)),
      throwsFormatException,
    );
  });

  test('presentation supports nested invitation output', () {
    final presentation = MobilePairingPolicy.presentation({
      'config': {'mobileRelayPairingInvite': invite},
    });

    expect(presentation?.pairingCode, '1234-5678');
    expect(presentation?.inviteText, startsWith('licoup://pair?invite='));
  });

  test('generic action projection excludes invitation secrets and tokens', () {
    final projection = MobilePairingPolicy.actionProjection({
      'ok': true,
      'pairingCode': '1234-5678',
      'expiresAt': '2099-01-01T00:00:00Z',
      'pcToken': 'private-token',
      'mobileRelayPairingInvite': invite,
      'rawResult': {'ciphertext': 'opaque'},
    });

    expect(projection, {
      'ok': true,
      'pairingCode': '1234-5678',
      'expiresAt': '2099-01-01T00:00:00Z',
    });
    expect(projection.toString(), isNot(contains('private-token')));
    expect(projection.toString(), isNot(contains('one-time-secret')));
    expect(projection.toString(), isNot(contains('ciphertext')));
  });
}
