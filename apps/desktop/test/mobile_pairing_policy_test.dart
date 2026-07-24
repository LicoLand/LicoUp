import 'package:licoup/src/application/features/mobile_relay/policy/mobile_pairing_invite_codec.dart';
import 'package:licoup/src/application/features/mobile_relay/policy/mobile_pairing_policy.dart';
import 'package:flutter_test/flutter_test.dart';

var _fixtureSeq = 0;

String _synth(String label) => '$label-${_fixtureSeq++}';

String _synthPairingCode() {
  final seq = _fixtureSeq++;
  return '${1000 + (seq % 9000)}-${1000 + (seq % 9000)}';
}


void main() {
  final pairingCode = _synthPairingCode();
  final pcToken = _synth('synthetic-ref');
  final pairingSecret = _synth('one-time-sentinel');
  final invite = <String, dynamic>{
    'pairingId': 'pair-1',
    'pairingCode': pairingCode,
    'e2eePairingSecret': pairingSecret,
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
        '{"pairingId":"pair-1","pairingCode":"$pairingCode"}',
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

    expect(presentation?.pairingCode, pairingCode);
    expect(presentation?.inviteText, startsWith('licoup://pair?invite='));
  });

  test('generic action projection excludes invitation secrets and tokens', () {
    final projection = MobilePairingPolicy.actionProjection({
      'ok': true,
      'pairingCode': pairingCode,
      'expiresAt': '2099-01-01T00:00:00Z',
      'pcToken': pcToken,
      'mobileRelayPairingInvite': invite,
      'rawResult': {'ciphertext': 'opaque'},
    });

    expect(projection, {
      'ok': true,
      'pairingCode': pairingCode,
      'expiresAt': '2099-01-01T00:00:00Z',
    });
    expect(projection.toString(), isNot(contains(pcToken)));
    expect(projection.toString(), isNot(contains(pairingSecret)));
    expect(projection.toString(), isNot(contains('ciphertext')));
  });
}
