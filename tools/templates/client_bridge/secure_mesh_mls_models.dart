enum SecureMeshMlsAction {
  status('secure_mesh.mls.status', false),
  participantEnsure('secure_mesh.mls.participant.ensure', true),
  keyPackageCreate('secure_mesh.mls.keyPackage.create', true),
  groupCreate('secure_mesh.mls.group.create', true),
  memberAdd('secure_mesh.mls.member.add', true),
  memberRemove('secure_mesh.mls.member.remove', true),
  groupJoin('secure_mesh.mls.group.join', true),
  commitProcess('secure_mesh.mls.commit.process', true),
  payloadSeal('secure_mesh.mls.payload.seal', true),
  payloadOpen('secure_mesh.mls.payload.open', true);

  const SecureMeshMlsAction(this.wireName, this.requiresAuthorization);

  final String wireName;
  final bool requiresAuthorization;
}

class SecureMeshMlsPublicIdentity {
  const SecureMeshMlsPublicIdentity({
    required this.endpointId,
    required this.identityPublicKeyBase64url,
    required this.signingPublicKeyBase64url,
    required this.rotationEpoch,
  });

  factory SecureMeshMlsPublicIdentity.fromJson(Map<String, dynamic> json) {
    return SecureMeshMlsPublicIdentity(
      endpointId: _requiredMlsString(json, 'endpointId'),
      identityPublicKeyBase64url: _requiredMlsString(
        json,
        'identityPublicKeyBase64url',
      ),
      signingPublicKeyBase64url: _requiredMlsString(
        json,
        'signingPublicKeyBase64url',
      ),
      rotationEpoch: _requiredMlsInt(json, 'rotationEpoch'),
    );
  }

  final String endpointId;
  final String identityPublicKeyBase64url;
  final String signingPublicKeyBase64url;
  final int rotationEpoch;

  Map<String, dynamic> toJson() => {
    'endpointId': endpointId,
    'identityPublicKeyBase64url': identityPublicKeyBase64url,
    'signingPublicKeyBase64url': signingPublicKeyBase64url,
    'rotationEpoch': rotationEpoch,
  };
}

class SecureMeshMlsTrustedIdentity {
  const SecureMeshMlsTrustedIdentity({required this.identity});

  final SecureMeshMlsPublicIdentity identity;

  Map<String, dynamic> toJson() => {'identity': identity.toJson()};
}

class SecureMeshMlsContentContext {
  const SecureMeshMlsContentContext({
    required this.envelopeId,
    required this.messageId,
    required this.opaqueMailboxId,
    required this.senderEndpointId,
    required this.recipientEndpointId,
    required this.sessionId,
    required this.createdAt,
    required this.expiresAt,
  });

  final String envelopeId;
  final String messageId;
  final String opaqueMailboxId;
  final String senderEndpointId;
  final String recipientEndpointId;
  final String sessionId;
  final String createdAt;
  final String expiresAt;

  Map<String, dynamic> toJson() => {
    'envelopeId': envelopeId,
    'messageId': messageId,
    'opaqueMailboxId': opaqueMailboxId,
    'senderEndpointId': senderEndpointId,
    'recipientEndpointId': recipientEndpointId,
    'sessionId': sessionId,
    'createdAt': createdAt,
    'expiresAt': expiresAt,
  };
}

class SecureMeshMlsRequest {
  const SecureMeshMlsRequest._(this.action, this.params);

  const SecureMeshMlsRequest.status()
    : this._(SecureMeshMlsAction.status, const {});

  factory SecureMeshMlsRequest.participantEnsure({
    bool allowInteraction = true,
  }) => SecureMeshMlsRequest._(SecureMeshMlsAction.participantEnsure, {
    'allowInteraction': allowInteraction,
  });

  factory SecureMeshMlsRequest.keyPackageCreate({
    bool allowInteraction = true,
  }) => SecureMeshMlsRequest._(SecureMeshMlsAction.keyPackageCreate, {
    'allowInteraction': allowInteraction,
  });

  factory SecureMeshMlsRequest.groupCreate({
    required String groupIdBase64url,
    bool allowInteraction = true,
  }) => SecureMeshMlsRequest._(SecureMeshMlsAction.groupCreate, {
    'groupIdBase64url': groupIdBase64url,
    'allowInteraction': allowInteraction,
  });

  factory SecureMeshMlsRequest.memberAdd({
    required String groupIdBase64url,
    required String memberKeyPackageId,
    required String memberKeyPackageBase64url,
    required SecureMeshMlsPublicIdentity memberIdentity,
    required Map<String, dynamic> memberCapabilityProof,
    required int memberDirectoryVersion,
    required int memberKeyPackageVersion,
    required Map<String, dynamic> untrustedDirectoryResponse,
    bool allowInteraction = true,
  }) {
    _requireMlsSafeInteger(memberDirectoryVersion, 'memberDirectoryVersion');
    _requireMlsSafeInteger(memberKeyPackageVersion, 'memberKeyPackageVersion');
    if (untrustedDirectoryResponse.isEmpty) {
      throw const FormatException(
        'Secure Mesh MLS untrustedDirectoryResponse is invalid.',
      );
    }
    return SecureMeshMlsRequest._(SecureMeshMlsAction.memberAdd, {
      'groupIdBase64url': groupIdBase64url,
      'memberKeyPackageId': memberKeyPackageId,
      'memberKeyPackageBase64url': memberKeyPackageBase64url,
      'memberIdentity': memberIdentity.toJson(),
      'memberCapabilityProof': Map<String, dynamic>.from(memberCapabilityProof),
      'memberDirectoryVersion': memberDirectoryVersion,
      'memberKeyPackageVersion': memberKeyPackageVersion,
      'untrustedDirectoryResponse': Map<String, dynamic>.from(
        untrustedDirectoryResponse,
      ),
      'allowInteraction': allowInteraction,
    });
  }

  factory SecureMeshMlsRequest.memberRemove({
    required String groupIdBase64url,
    required int expectedEpoch,
    required SecureMeshMlsPublicIdentity memberIdentity,
    bool allowInteraction = true,
  }) {
    _requireMlsSafeInteger(expectedEpoch, 'expectedEpoch');
    return SecureMeshMlsRequest._(SecureMeshMlsAction.memberRemove, {
      'groupIdBase64url': groupIdBase64url,
      'expectedEpoch': expectedEpoch,
      'memberIdentity': memberIdentity.toJson(),
      'allowInteraction': allowInteraction,
    });
  }

  factory SecureMeshMlsRequest.groupJoin({
    required String groupIdBase64url,
    required SecureMeshMlsPublicIdentity inviterIdentity,
    required List<String> expectedRosterEndpointIds,
    required List<SecureMeshMlsTrustedIdentity> trustedRoster,
    required String welcomeMessageBase64url,
    bool allowInteraction = true,
  }) => SecureMeshMlsRequest._(SecureMeshMlsAction.groupJoin, {
    'groupIdBase64url': groupIdBase64url,
    'inviterIdentity': inviterIdentity.toJson(),
    'expectedRosterEndpointIds': List<String>.from(expectedRosterEndpointIds),
    'trustedRoster': trustedRoster.map((entry) => entry.toJson()).toList(),
    'welcomeMessageBase64url': welcomeMessageBase64url,
    'allowInteraction': allowInteraction,
  });

  factory SecureMeshMlsRequest.commitProcess({
    required String groupIdBase64url,
    required SecureMeshMlsPublicIdentity committerIdentity,
    SecureMeshMlsPublicIdentity? addedMemberIdentity,
    required List<SecureMeshMlsTrustedIdentity> trustedRoster,
    required String commitMessageBase64url,
    bool allowInteraction = true,
  }) => SecureMeshMlsRequest._(SecureMeshMlsAction.commitProcess, {
    'groupIdBase64url': groupIdBase64url,
    'committerIdentity': committerIdentity.toJson(),
    if (addedMemberIdentity != null)
      'addedMemberIdentity': addedMemberIdentity.toJson(),
    'trustedRoster': trustedRoster.map((entry) => entry.toJson()).toList(),
    'commitMessageBase64url': commitMessageBase64url,
    'allowInteraction': allowInteraction,
  });

  factory SecureMeshMlsRequest.payloadSeal({
    required String groupIdBase64url,
    required List<SecureMeshMlsTrustedIdentity> trustedRoster,
    required SecureMeshMlsContentContext context,
    required String payloadKind,
    required String bodyBase64url,
    String? contentType,
    bool allowInteraction = true,
  }) => SecureMeshMlsRequest._(SecureMeshMlsAction.payloadSeal, {
    'groupIdBase64url': groupIdBase64url,
    'trustedRoster': trustedRoster.map((entry) => entry.toJson()).toList(),
    'context': context.toJson(),
    'payloadKind': payloadKind,
    'bodyBase64url': bodyBase64url,
    if (contentType != null && contentType.trim().isNotEmpty)
      'contentType': contentType.trim(),
    'allowInteraction': allowInteraction,
  });

  factory SecureMeshMlsRequest.payloadOpen({
    required String groupIdBase64url,
    required SecureMeshMlsPublicIdentity trustedSenderIdentity,
    required List<SecureMeshMlsTrustedIdentity> trustedRoster,
    required SecureMeshMlsContentContext context,
    required String expectedPayloadKind,
    required String messageBase64url,
    bool allowInteraction = true,
  }) => SecureMeshMlsRequest._(SecureMeshMlsAction.payloadOpen, {
    'groupIdBase64url': groupIdBase64url,
    'trustedSenderIdentity': trustedSenderIdentity.toJson(),
    'trustedRoster': trustedRoster.map((entry) => entry.toJson()).toList(),
    'context': context.toJson(),
    'expectedPayloadKind': expectedPayloadKind,
    'messageBase64url': messageBase64url,
    'allowInteraction': allowInteraction,
  });

  final SecureMeshMlsAction action;
  final Map<String, dynamic> params;
}

class SecureMeshMlsResponse {
  SecureMeshMlsResponse._(this.value);

  factory SecureMeshMlsResponse.fromJson(Map<String, dynamic> json) {
    if (json['ok'] != true) {
      throw FormatException('Secure Mesh MLS native action failed closed.');
    }
    if (json.containsKey('privateKeyMaterial') &&
        json['privateKeyMaterial'] != 'redacted') {
      throw FormatException('Secure Mesh MLS response exposed key material.');
    }
    return SecureMeshMlsResponse._(Map<String, dynamic>.unmodifiable(json));
  }

  final Map<String, dynamic> value;
}

String _requiredMlsString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('Secure Mesh MLS $key is invalid.');
  }
  return value;
}

int _requiredMlsInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! int || value < 0) {
    throw FormatException('Secure Mesh MLS $key is invalid.');
  }
  return value;
}

const int _maxJsonSafeInteger = 9007199254740991;

void _requireMlsSafeInteger(int value, String key) {
  if (value < 0 || value > _maxJsonSafeInteger) {
    throw FormatException(
      'Secure Mesh MLS $key is outside the safe integer range.',
    );
  }
}
