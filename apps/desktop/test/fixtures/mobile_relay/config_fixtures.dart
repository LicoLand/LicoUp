Map<String, dynamic> mobileRelayConfigJson({
  bool useCustomGateway = false,
  String customGatewayUrl = '',
  String pairingId = '',
  String pcToken = '',
  String lastPairingCode = '',
  String lastPairingExpiresAt = '',
}) {
  return {
    'schemaVersion': 1,
    'defaultGatewayUrl': 'https://relay.example.test',
    'useCustomGateway': useCustomGateway,
    'customGatewayUrl': customGatewayUrl,
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
