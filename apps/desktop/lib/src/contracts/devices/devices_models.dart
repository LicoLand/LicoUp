/// Value models of the CLI `devices` command group (desktop-to-desktop
/// pairing over LicoArc and agent messages to paired devices).
library;

/// One device this client has paired with.
final class DevicePeer {
  const DevicePeer({
    required this.peerId,
    required this.label,
    required this.pairedAt,
  });

  factory DevicePeer.fromJson(Map<String, dynamic> json) => DevicePeer(
    peerId: _requiredText(json['peerId']),
    label: _text(json['label']),
    pairedAt: _text(json['pairedAt']),
  );

  final String peerId;
  final String label;
  final String pairedAt;

  @override
  bool operator ==(Object other) =>
      other is DevicePeer &&
      other.peerId == peerId &&
      other.label == label &&
      other.pairedAt == pairedAt;

  @override
  int get hashCode => Object.hash(peerId, label, pairedAt);
}

enum DevicePairingRole {
  offerer('offerer'),
  claimer('claimer');

  const DevicePairingRole(this.wireName);

  final String wireName;
}

enum DevicePairingState {
  awaitingClaim('awaiting-claim'),
  awaitingReply('awaiting-reply'),
  completed('completed'),
  failed('failed');

  const DevicePairingState(this.wireName);

  final String wireName;

  /// Whether the pairing can still advance or be cancelled.
  bool get pending => this == awaitingClaim || this == awaitingReply;
}

/// One pairing this client offered or claimed.
final class DevicePairing {
  const DevicePairing({
    required this.pairingId,
    required this.role,
    required this.state,
    required this.createdAt,
  });

  factory DevicePairing.fromJson(Map<String, dynamic> json) => DevicePairing(
    pairingId: _requiredText(json['pairingId']),
    role: _wireValue(DevicePairingRole.values, json['role'], (v) => v.wireName),
    state: _wireValue(
      DevicePairingState.values,
      json['state'],
      (v) => v.wireName,
    ),
    createdAt: _text(json['createdAt']),
  );

  final String pairingId;
  final DevicePairingRole role;
  final DevicePairingState state;
  final String createdAt;

  @override
  bool operator ==(Object other) =>
      other is DevicePairing &&
      other.pairingId == pairingId &&
      other.role == role &&
      other.state == state &&
      other.createdAt == createdAt;

  @override
  int get hashCode => Object.hash(pairingId, role, state, createdAt);
}

/// The answer of `devices status`.
final class DevicesStatus {
  DevicesStatus({
    required this.enrolled,
    required this.legacyPairingsDetected,
    required this.station,
    required this.mailboxId,
    required Iterable<DevicePeer> peers,
    required Iterable<DevicePairing> pairings,
  }) : peers = List<DevicePeer>.unmodifiable(peers),
       pairings = List<DevicePairing>.unmodifiable(pairings);

  factory DevicesStatus.fromJson(Map<String, dynamic> json) {
    if (json['ok'] != true || json['enrolled'] is! bool) {
      throw const FormatException('devices_status_invalid');
    }
    return DevicesStatus(
      enrolled: json['enrolled'] as bool,
      legacyPairingsDetected: json['legacyPairingsDetected'] == true,
      station: _text(json['station']),
      mailboxId: _text(json['mailboxId']),
      peers: _objects(json['peers']).map(DevicePeer.fromJson),
      pairings: _objects(json['pairings']).map(DevicePairing.fromJson),
    );
  }

  static final DevicesStatus unknown = DevicesStatus(
    enrolled: false,
    legacyPairingsDetected: false,
    station: '',
    mailboxId: '',
    peers: const <DevicePeer>[],
    pairings: const <DevicePairing>[],
  );

  final bool enrolled;

  /// Pre-0.3.0 pairing state exists under the data home; those pairings are
  /// not migrated and the devices must pair again.
  final bool legacyPairingsDetected;
  final String station;
  final String mailboxId;
  final List<DevicePeer> peers;
  final List<DevicePairing> pairings;

  bool get hasPendingPairing =>
      pairings.any((pairing) => pairing.state.pending);
}

/// The answer of `devices pair offer`: the one copyable code the other
/// device claims.
final class DevicePairingOffer {
  const DevicePairingOffer({required this.pairingId, required this.code});

  factory DevicePairingOffer.fromJson(Map<String, dynamic> json) {
    if (json['ok'] != true) {
      throw const FormatException('devices_pair_offer_invalid');
    }
    return DevicePairingOffer(
      pairingId: _requiredText(json['pairingId']),
      code: _requiredText(json['code']),
    );
  }

  final String pairingId;
  final String code;

  @override
  bool operator ==(Object other) =>
      other is DevicePairingOffer &&
      other.pairingId == pairingId &&
      other.code == code;

  @override
  int get hashCode => Object.hash(pairingId, code);
}

enum DeviceMessageStatus {
  completed('completed'),
  failed('failed');

  const DeviceMessageStatus(this.wireName);

  final String wireName;
}

/// One agent message result a paired device returned.
final class DeviceMessageResult {
  DeviceMessageResult({
    required this.commandId,
    required this.peerId,
    required this.status,
    required Map<String, Object?> output,
    required this.completedAt,
  }) : output = Map<String, Object?>.unmodifiable(output);

  factory DeviceMessageResult.fromJson(Map<String, dynamic> json) {
    final output = json['output'];
    if (output is! Map) {
      throw const FormatException('devices_message_result_invalid');
    }
    return DeviceMessageResult(
      commandId: _requiredText(json['commandId']),
      peerId: _requiredText(json['peerId']),
      status: _wireValue(
        DeviceMessageStatus.values,
        json['status'],
        (v) => v.wireName,
      ),
      output: output.map((key, value) => MapEntry('$key', value)),
      completedAt: _text(json['completedAt']),
    );
  }

  final String commandId;
  final String peerId;
  final DeviceMessageStatus status;
  final Map<String, Object?> output;
  final String completedAt;
}

/// Parses the `results` array of `devices message results`.
List<DeviceMessageResult> deviceMessageResultsFromJson(
  Map<String, dynamic> json,
) {
  if (json['ok'] != true || json['results'] is! List) {
    throw const FormatException('devices_message_results_invalid');
  }
  return List<DeviceMessageResult>.unmodifiable(
    _objects(json['results']).map(DeviceMessageResult.fromJson),
  );
}

String _text(Object? value) => value is String ? value.trim() : '';

String _requiredText(Object? value) {
  final text = _text(value);
  if (text.isEmpty) throw const FormatException('devices_payload_invalid');
  return text;
}

Iterable<Map<String, dynamic>> _objects(Object? value) {
  if (value == null) return const <Map<String, dynamic>>[];
  if (value is! List) throw const FormatException('devices_payload_invalid');
  return value.map((item) {
    if (item is! Map) throw const FormatException('devices_payload_invalid');
    return item.map((key, entry) => MapEntry('$key', entry));
  });
}

T _wireValue<T>(List<T> values, Object? raw, String Function(T) wireName) {
  for (final value in values) {
    if (wireName(value) == raw) return value;
  }
  throw const FormatException('devices_payload_invalid');
}
