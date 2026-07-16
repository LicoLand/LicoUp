import 'package:flutter_client/src/application/features/mobile_relay/policy/mobile_pairing_invite_codec.dart';
import 'package:flutter_client/src/contracts/mobile_pairing_presentation.dart';

/// Pure presentation and disclosure policy for pairing results.
abstract final class MobilePairingPolicy {
  static MobilePairingPresentation? presentation(Map<String, dynamic>? result) {
    final invite = _invite(result);
    final resultCode = _text(result?['pairingCode']);
    final pairingCode = resultCode.isNotEmpty
        ? resultCode
        : _text(invite?['pairingCode']);
    final inviteText = invite == null
        ? ''
        : MobilePairingInviteCodec.encodeLink(invite);
    final presentation = MobilePairingPresentation(
      pairingCode: pairingCode,
      inviteText: inviteText,
    );
    return presentation.isEmpty ? null : presentation;
  }

  /// Keeps generic state surfaces free of invitation secrets and raw output.
  static Map<String, dynamic>? actionProjection(Map<String, dynamic>? result) {
    if (result == null) {
      return null;
    }
    final projection = <String, dynamic>{
      'ok': result['ok'] == true,
      if (_text(result['status']).isNotEmpty)
        'status': _stableCode(result['status']),
      if (_text(result['code']).isNotEmpty) 'code': _stableCode(result['code']),
      if (_text(result['pairingCode']).isNotEmpty)
        'pairingCode': _text(result['pairingCode']),
      if (_text(result['expiresAt']).isNotEmpty)
        'expiresAt': _text(result['expiresAt']),
    };
    return Map<String, dynamic>.unmodifiable(projection);
  }

  static Map<String, dynamic>? _invite(Map<String, dynamic>? result) {
    final direct = result?['mobileRelayPairingInvite'];
    if (direct is Map) {
      return Map<String, dynamic>.from(direct);
    }
    final config = result?['config'];
    if (config is Map) {
      final nested = config['mobileRelayPairingInvite'];
      if (nested is Map) {
        return Map<String, dynamic>.from(nested);
      }
    }
    return null;
  }

  static String _text(Object? value) => value?.toString().trim() ?? '';

  static String _stableCode(Object? value) {
    final candidate = _text(value).toLowerCase();
    return RegExp(r'^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$').hasMatch(candidate)
        ? candidate
        : 'mobile_relay_status_unavailable';
  }
}
