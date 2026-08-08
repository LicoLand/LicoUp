import 'dart:io' show Platform;

import 'package:licoup/src/contracts/mobile_relay/mobile_relay_models.dart';

/// Privacy-bounded projection from native relay output to client config.
final class MobileRelayConfigProjector {
  const MobileRelayConfigProjector();

  MobileRelayConfig fromOutput(Map<String, dynamic> output) {
    final rawConfig = output['config'];
    final config = rawConfig is Map<String, dynamic>
        ? Map<String, dynamic>.from(rawConfig)
        : Map<String, dynamic>.from(output);
    _mergePairedDeviceEcho(config, output);
    return MobileRelayConfig.fromJson(
      config,
      pcClientName: Platform.isMacOS ? 'Mac' : 'Desktop',
    );
  }

  void _mergePairedDeviceEcho(
    Map<String, dynamic> config,
    Map<String, dynamic> output,
  ) {
    final pairing = output['pairing'];
    final pc = pairing is Map ? pairing['pc'] : null;
    if (pc is! Map) {
      return;
    }
    final pairingId = _firstNonBlank([
      output['pairingId'],
      config['pairingId'],
    ]);
    if (pairingId.isEmpty) {
      return;
    }
    final pcClientId = _firstNonBlank([
      pc['pcClientId'],
      pc['clientId'],
      pc['id'],
      output['pcClientId'],
      config['pcClientId'],
    ]);
    final pcClientName = _firstNonBlank([
      pc['pcClientName'],
      pc['clientName'],
      pc['name'],
      output['pcClientName'],
      config['pcClientName'],
      'Desktop',
    ]);
    final devices = config['pairedDevices'] is List
        ? List<Object?>.from(config['pairedDevices'] as List)
        : <Object?>[];
    for (var index = 0; index < devices.length; index += 1) {
      final device = devices[index];
      if (device is! Map) {
        continue;
      }
      final existingPairing = (device['pairingId'] ?? '').toString().trim();
      final existingId = (device['pcClientId'] ?? device['id'] ?? '')
          .toString()
          .trim();
      if (existingPairing != pairingId &&
          (pcClientId.isEmpty || existingId != pcClientId)) {
        continue;
      }
      final updated = Map<String, dynamic>.from(device);
      if (pcClientId.isNotEmpty) {
        updated['id'] = pcClientId;
        updated['pcClientId'] = pcClientId;
      }
      updated['pcClientName'] = pcClientName;
      updated['pairingId'] = pairingId;
      updated['credentialPresent'] = _credentialPresent(
        config,
        output,
        pairing,
      );
      updated['stationBaseUrl'] = _stationEcho(config, output);
      devices[index] = updated;
      config['pairedDevices'] = devices;
      return;
    }
    devices.add({
      'id': pcClientId.isNotEmpty ? pcClientId : pairingId,
      'pcClientId': pcClientId,
      'pcClientName': pcClientName,
      'pairingId': pairingId,
      'credentialPresent': _credentialPresent(config, output, pairing),
      'stationBaseUrl': _stationEcho(config, output),
    });
    config['pairedDevices'] = devices;
  }

  bool _credentialPresent(
    Map<String, dynamic> config,
    Map<String, dynamic> output,
    Map pairing,
  ) {
    final mobile = pairing['mobile'];
    return config['mobileTokenPresent'] == true ||
        output['mobileTokenPresent'] == true ||
        _firstNonBlank([
          config['mobileToken'],
          output['mobileToken'],
        ]).isNotEmpty ||
        (mobile is Map &&
            _firstNonBlank([
              mobile['mobileToken'],
              mobile['token'],
            ]).isNotEmpty);
  }

  String _stationEcho(
    Map<String, dynamic> config,
    Map<String, dynamic> output,
  ) {
    return normalizeMobileRelayStationBaseUrl(
      _firstNonBlank([output['stationBaseUrl'], config['stationBaseUrl']]),
    );
  }

  String _firstNonBlank(Iterable<Object?> values) {
    for (final value in values) {
      final text = value?.toString().trim() ?? '';
      if (text.isNotEmpty) {
        return text;
      }
    }
    return '';
  }
}
