/// Dart projection of the fixed `provider-quota snapshot` wire contract.
///
/// The native pipeline emits one snapshot per agent that has a quota source;
/// agents without a source are omitted entirely, and no field ever carries
/// credential material — only quota metrics and identity labels. The Flutter
/// side renders from this projection and never merges Maps.
library;

/// Envelope schema marker of the fixed wire contract.
const String providerQuotaSnapshotsSchema = 'v0.0.1:provider-quota-snapshots-1';

Map<String, dynamic> _map(Object? value) {
  return value is Map<String, dynamic>
      ? Map<String, dynamic>.from(value)
      : const {};
}

int _int(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

double _double(Object? value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '') ?? 0;
}

String _text(Object? value, {int maxLength = 256}) {
  final text = value?.toString().trim() ?? '';
  if (text.isEmpty || text.length > maxLength) return '';
  if (text.runes.any((rune) => rune < 0x20 || rune == 0x7f)) return '';
  return text;
}

String? _optionalText(Object? value) {
  final text = _text(value);
  return text.isEmpty ? null : text;
}

/// Freshness state of one provider quota snapshot. `unavailable` means the
/// provider has a quota source but no usable fetch; the UI renders nothing
/// for it rather than fake data.
enum ProviderQuotaStatus {
  live,
  stale,
  unavailable;

  static ProviderQuotaStatus parse(Object? value) {
    return switch (value?.toString().trim()) {
      'live' => ProviderQuotaStatus.live,
      'stale' => ProviderQuotaStatus.stale,
      _ => ProviderQuotaStatus.unavailable,
    };
  }

  String get wireName => name;
}

/// One quota window (for example Codex primary/secondary). [usedPercent] is
/// the raw provider value and may exceed 100; the UI clamps it for display.
class ProviderQuotaWindow {
  const ProviderQuotaWindow({
    required this.label,
    required this.usedPercent,
    this.windowMinutes,
    this.resetsAt,
    this.resetDescription = '',
  });

  final String label;
  final double usedPercent;
  final int? windowMinutes;

  /// RFC 3339 reset timestamp; backfilled from cache by the native scheduler
  /// when a fetch omits it.
  final String? resetsAt;
  final String resetDescription;

  double get clampedUsedPercent => usedPercent.clamp(0.0, 100.0).toDouble();

  DateTime? get resetsAtTime => DateTime.tryParse(resetsAt ?? '')?.toUtc();

  factory ProviderQuotaWindow.fromJson(Object? raw) {
    final json = _map(raw);
    return ProviderQuotaWindow(
      label: _text(json['label']),
      usedPercent: _double(json['usedPercent']),
      windowMinutes: json['windowMinutes'] == null
          ? null
          : _int(json['windowMinutes']),
      resetsAt: _optionalText(json['resetsAt']),
      resetDescription: _text(json['resetDescription']),
    );
  }

  Map<String, dynamic> toJson() => {
    'label': label,
    'usedPercent': usedPercent,
    'windowMinutes': windowMinutes,
    'resetsAt': resetsAt,
    'resetDescription': resetDescription,
  };
}

/// Quota-account identity labels. Never credential material.
class ProviderQuotaIdentity {
  const ProviderQuotaIdentity({this.accountLabel, this.plan});

  final String? accountLabel;
  final String? plan;

  factory ProviderQuotaIdentity.fromJson(Object? raw) {
    final json = _map(raw);
    return ProviderQuotaIdentity(
      accountLabel: _optionalText(json['accountLabel']),
      plan: _optionalText(json['plan']),
    );
  }

  Map<String, dynamic> toJson() => {'accountLabel': accountLabel, 'plan': plan};
}

/// One agent's provider quota snapshot. The ring and hover card render only
/// when [hasQuotaWindows] is true; a missing or unusable snapshot paints
/// nothing.
class ProviderQuotaSnapshot {
  const ProviderQuotaSnapshot({
    required this.agentId,
    required this.provider,
    required this.status,
    required this.windows,
    required this.identity,
    required this.capturedAt,
    required this.staleAfterSeconds,
  });

  final String agentId;
  final String provider;
  final ProviderQuotaStatus status;
  final List<ProviderQuotaWindow> windows;
  final ProviderQuotaIdentity identity;
  final String capturedAt;
  final int staleAfterSeconds;

  bool get isStale => status == ProviderQuotaStatus.stale;

  /// Whether the UI may render quota chrome for this snapshot. Unavailable
  /// or window-less snapshots render no ring and no card.
  bool get hasQuotaWindows =>
      status != ProviderQuotaStatus.unavailable && windows.isNotEmpty;

  /// Ring sweep driver: the most constrained window, clamped for display.
  double get ringUsedPercent {
    var value = 0.0;
    for (final window in windows) {
      if (window.usedPercent > value) value = window.usedPercent;
    }
    return value.clamp(0.0, 100.0).toDouble();
  }

  DateTime? get capturedAtTime => DateTime.tryParse(capturedAt)?.toUtc();

  /// Capture age for the stale-data caption; null when the timestamp is
  /// unparsable or in the future.
  Duration? captureAge({DateTime? now}) {
    final captured = capturedAtTime;
    if (captured == null) return null;
    final age = (now ?? DateTime.now()).toUtc().difference(captured);
    return age.isNegative ? null : age;
  }

  factory ProviderQuotaSnapshot.fromJson(Object? raw) {
    final json = _map(raw);
    final windows = <ProviderQuotaWindow>[
      if (json['windows'] is List)
        for (final item in json['windows'] as List)
          ProviderQuotaWindow.fromJson(item),
    ];
    return ProviderQuotaSnapshot(
      agentId: _text(json['agentId']),
      provider: _text(json['provider']),
      status: ProviderQuotaStatus.parse(json['status']),
      windows: List.unmodifiable(windows),
      identity: ProviderQuotaIdentity.fromJson(json['identity']),
      capturedAt: _text(json['capturedAt']),
      staleAfterSeconds: _int(json['staleAfterSeconds']).clamp(0, 0x7fffffff),
    );
  }

  Map<String, dynamic> toJson() => {
    'agentId': agentId,
    'provider': provider,
    'status': status.wireName,
    'windows': [for (final window in windows) window.toJson()],
    'identity': identity.toJson(),
    'capturedAt': capturedAt,
    'staleAfterSeconds': staleAfterSeconds,
  };
}

/// Envelope of the fixed `provider-quota snapshot` wire contract.
class ProviderQuotaSnapshotReport {
  const ProviderQuotaSnapshotReport({
    required this.schemaVersion,
    required this.generatedAt,
    required this.snapshots,
  });

  final String schemaVersion;
  final String generatedAt;
  final List<ProviderQuotaSnapshot> snapshots;

  /// Immutable projection keyed by agent id, handed to the roster as plain
  /// state. Agents without a quota source are absent.
  Map<String, ProviderQuotaSnapshot> get byAgentId => Map.unmodifiable({
    for (final snapshot in snapshots) snapshot.agentId: snapshot,
  });

  factory ProviderQuotaSnapshotReport.fromJson(Map<String, dynamic> json) {
    if (json['schemaVersion'] != providerQuotaSnapshotsSchema) {
      throw const FormatException(
        'Unsupported provider quota snapshots schema.',
      );
    }
    final snapshots = <ProviderQuotaSnapshot>[
      if (json['snapshots'] is List)
        for (final item in json['snapshots'] as List)
          ProviderQuotaSnapshot.fromJson(item),
    ]..removeWhere((snapshot) => snapshot.agentId.isEmpty);
    return ProviderQuotaSnapshotReport(
      schemaVersion: providerQuotaSnapshotsSchema,
      generatedAt: _text(json['generatedAt']),
      snapshots: List.unmodifiable(snapshots),
    );
  }
}
