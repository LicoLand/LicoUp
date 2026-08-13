Map<String, dynamic> mobileRelayConfigJson({
  String stationBaseUrl = 'https://station.example.test',
  String pairingId = '',
  String pcToken = '',
  String lastPairingCode = '',
  String lastPairingExpiresAt = '',
}) {
  return {
    'schemaVersion': 2,
    'stationBaseUrl': stationBaseUrl,
    'pcClientId': 'pc-test',
    'pcClientName': 'Test PC',
    'pairingId': pairingId,
    'pcToken': pcToken,
    'lastPairingCode': lastPairingCode,
    'lastPairingExpiresAt': lastPairingExpiresAt,
    'paired': false,
    'relayEnabled': false,
    'pollIntervalSeconds': 5,
  };
}
