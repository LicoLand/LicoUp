enum SecureMeshKtAction {
  configureAuthority('secure_mesh.kt.configureAuthority', true),
  publicationRequest('secure_mesh.kt.publicationRequest', true),
  revocationRequest('secure_mesh.kt.revocationRequest', true),
  provision('secure_mesh.kt.provision', true),
  gossip('secure_mesh.kt.gossip', true),
  selfMonitor('secure_mesh.kt.selfMonitor', true),
  status('secure_mesh.kt.status', false);

  const SecureMeshKtAction(this.wireName, this.requiresAuthorization);

  final String wireName;
  final bool requiresAuthorization;
}

class SecureMeshKtPinnedAuthority {
  const SecureMeshKtPinnedAuthority({
    required this.logId,
    required this.keyId,
    required this.publicKeyHex,
  });

  final String logId;
  final String keyId;
  final String publicKeyHex;

  Map<String, dynamic> toJson() {
    _requireKtText(logId, 'logId');
    _requireKtText(keyId, 'keyId');
    _requireKtSha256Hex(publicKeyHex, 'publicKeyHex');
    return {
      'logId': logId,
      'keyId': keyId,
      'publicKeyHex': publicKeyHex,
      'provenance': 'user-configured-external',
    };
  }
}

class SecureMeshKtRequest {
  const SecureMeshKtRequest._(this.action, this.params);

  factory SecureMeshKtRequest.prepareAuthority({
    required SecureMeshKtPinnedAuthority authority,
    required String directoryScopeCommitment,
    int maxSthAgeSeconds = 3600,
    int maxFutureSkewSeconds = 300,
    bool replaceExistingAuthority = false,
  }) {
    _requireKtSha256Hex(directoryScopeCommitment, 'directoryScopeCommitment');
    _requireKtPositiveSafeInteger(maxSthAgeSeconds, 'maxSthAgeSeconds');
    _requireKtSafeInteger(maxFutureSkewSeconds, 'maxFutureSkewSeconds');
    return SecureMeshKtRequest._(SecureMeshKtAction.configureAuthority, {
      'operation': 'prepare',
      if (replaceExistingAuthority)
        'confirmSecurityReset': 'RESET_KEY_TRANSPARENCY_AUTHORITY',
      'directoryScopeCommitment': directoryScopeCommitment,
      'pin': authority.toJson(),
      'maxSthAgeSeconds': maxSthAgeSeconds,
      'maxFutureSkewSeconds': maxFutureSkewSeconds,
    });
  }

  factory SecureMeshKtRequest.confirmAuthority({
    required SecureMeshKtPinnedAuthority authority,
    required String directoryScopeCommitment,
    required String authorityChallengeId,
    required bool confirmAuthorityConfiguration,
    int maxSthAgeSeconds = 3600,
    int maxFutureSkewSeconds = 300,
    bool replaceExistingAuthority = false,
    bool allowInteraction = true,
  }) {
    _requireKtSha256Hex(directoryScopeCommitment, 'directoryScopeCommitment');
    _requireKtText(authorityChallengeId, 'authorityChallengeId');
    _requireKtPositiveSafeInteger(maxSthAgeSeconds, 'maxSthAgeSeconds');
    _requireKtSafeInteger(maxFutureSkewSeconds, 'maxFutureSkewSeconds');
    return SecureMeshKtRequest._(SecureMeshKtAction.configureAuthority, {
      'operation': 'confirm',
      'authorityChallengeId': authorityChallengeId.trim(),
      'confirmAuthorityConfiguration': confirmAuthorityConfiguration,
      if (replaceExistingAuthority)
        'confirmSecurityReset': 'RESET_KEY_TRANSPARENCY_AUTHORITY',
      'directoryScopeCommitment': directoryScopeCommitment,
      'pin': authority.toJson(),
      'maxSthAgeSeconds': maxSthAgeSeconds,
      'maxFutureSkewSeconds': maxFutureSkewSeconds,
      'allowInteraction': allowInteraction,
    });
  }

  factory SecureMeshKtRequest.publicationRequest({
    String endpointKind = '',
    bool allowInteraction = true,
  }) => SecureMeshKtRequest._(SecureMeshKtAction.publicationRequest, {
    if (endpointKind.trim().isNotEmpty) 'endpointKind': endpointKind.trim(),
    'allowInteraction': allowInteraction,
  });

  factory SecureMeshKtRequest.revocationRequest({
    required bool confirmRevocation,
    bool allowInteraction = true,
  }) => SecureMeshKtRequest._(SecureMeshKtAction.revocationRequest, {
    'confirmRevocation': confirmRevocation,
    'allowInteraction': allowInteraction,
  });

  factory SecureMeshKtRequest.provision({
    required Map<String, dynamic> response,
    bool allowInteraction = true,
  }) => SecureMeshKtRequest._(SecureMeshKtAction.provision, {
    'response': _requireKtObject(response, 'response'),
    'allowInteraction': allowInteraction,
  });

  factory SecureMeshKtRequest.selfMonitor({
    required Map<String, dynamic> response,
    bool allowInteraction = true,
  }) => SecureMeshKtRequest._(SecureMeshKtAction.selfMonitor, {
    'response': _requireKtObject(response, 'response'),
    'allowInteraction': allowInteraction,
  });

  factory SecureMeshKtRequest.gossipSeal({
    required Map<String, dynamic> gossip,
    bool allowInteraction = true,
  }) => SecureMeshKtRequest._(SecureMeshKtAction.gossip, {
    'operation': 'seal',
    'gossip': _requireKtObject(gossip, 'gossip'),
    'allowInteraction': allowInteraction,
  });

  factory SecureMeshKtRequest.gossipOpen({
    required Map<String, dynamic> secureEnvelope,
    bool allowInteraction = true,
  }) => SecureMeshKtRequest._(SecureMeshKtAction.gossip, {
    'operation': 'open',
    'secureEnvelope': _requireKtObject(secureEnvelope, 'secureEnvelope'),
    'allowInteraction': allowInteraction,
  });

  const SecureMeshKtRequest.status()
    : this._(SecureMeshKtAction.status, const {});

  final SecureMeshKtAction action;
  final Map<String, dynamic> params;
}

class SecureMeshKtResponse {
  SecureMeshKtResponse._(this.value);

  factory SecureMeshKtResponse.fromJson(Map<String, dynamic> json) {
    if (json['ok'] != true) {
      throw const FormatException(
        'Secure Mesh KT native action failed closed.',
      );
    }
    if (json.containsKey('privateKeyMaterial') &&
        json['privateKeyMaterial'] != 'redacted') {
      throw const FormatException(
        'Secure Mesh KT response exposed key material.',
      );
    }
    return SecureMeshKtResponse._(Map<String, dynamic>.unmodifiable(json));
  }

  final Map<String, dynamic> value;
}

const int _maxKtJsonSafeInteger = 9007199254740991;

Map<String, dynamic> _requireKtObject(
  Map<String, dynamic> value,
  String label,
) {
  if (value.isEmpty) {
    throw FormatException('Secure Mesh KT $label is invalid.');
  }
  return Map<String, dynamic>.from(value);
}

void _requireKtText(String value, String label) {
  if (value.trim().isEmpty || value.length > 8192) {
    throw FormatException('Secure Mesh KT $label is invalid.');
  }
}

void _requireKtSha256Hex(String value, String label) {
  final normalized = value.trim();
  if (normalized.length != 64 ||
      !RegExp(r'^[0-9a-f]{64}$').hasMatch(normalized)) {
    throw FormatException('Secure Mesh KT $label is invalid.');
  }
}

void _requireKtSafeInteger(int value, String label) {
  if (value < 0 || value > _maxKtJsonSafeInteger) {
    throw FormatException('Secure Mesh KT $label is outside the safe range.');
  }
}

void _requireKtPositiveSafeInteger(int value, String label) {
  _requireKtSafeInteger(value, label);
  if (value == 0) {
    throw FormatException('Secure Mesh KT $label must be positive.');
  }
}
