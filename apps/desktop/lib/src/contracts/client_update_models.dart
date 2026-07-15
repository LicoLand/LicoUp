/// Client update status projection for Settings UI (public metadata only).
enum ClientUpdatePhase {
  idle,
  checking,
  upToDate,
  updateAvailable,
  downloading,
  downloaded,
  verifying,
  verified,
  applyPlanned,
  failed,
}

final class ClientUpdateStatus {
  const ClientUpdateStatus({
    required this.phase,
    required this.currentVersion,
    required this.channel,
    this.availableVersion = '',
    this.releaseNotesUrl = '',
    this.verifiedKeyIds = const [],
    this.artifactSha256 = '',
    this.stagedBytes = 0,
    this.totalBytes = 0,
    this.errorCode = '',
    this.productionReady = false,
    this.updateAvailable = false,
    this.restartRequired = false,
  });

  final ClientUpdatePhase phase;
  final String currentVersion;
  final String channel;
  final String availableVersion;
  final String releaseNotesUrl;
  final List<String> verifiedKeyIds;
  final String artifactSha256;
  final int stagedBytes;
  final int totalBytes;
  final String errorCode;
  final bool productionReady;
  final bool updateAvailable;
  final bool restartRequired;

  factory ClientUpdateStatus.idle({
    String currentVersion = '',
    String channel = 'stable',
  }) {
    return ClientUpdateStatus(
      phase: ClientUpdatePhase.idle,
      currentVersion: currentVersion,
      channel: channel,
    );
  }

  factory ClientUpdateStatus.fromJson(Map<String, dynamic> json) {
    final phaseRaw = (json['phase'] as String?)?.trim() ?? 'idle';
    return ClientUpdateStatus(
      phase: switch (phaseRaw) {
        'checking' => ClientUpdatePhase.checking,
        'upToDate' => ClientUpdatePhase.upToDate,
        'updateAvailable' => ClientUpdatePhase.updateAvailable,
        'downloading' => ClientUpdatePhase.downloading,
        'downloaded' => ClientUpdatePhase.downloaded,
        'verifying' => ClientUpdatePhase.verifying,
        'verified' => ClientUpdatePhase.verified,
        'applyPlanned' => ClientUpdatePhase.applyPlanned,
        'failed' => ClientUpdatePhase.failed,
        _ => ClientUpdatePhase.idle,
      },
      currentVersion: (json['currentVersion'] as String?)?.trim() ?? '',
      channel: (json['channel'] as String?)?.trim() ?? 'stable',
      availableVersion: (json['availableVersion'] as String?)?.trim() ?? '',
      releaseNotesUrl: (json['releaseNotesUrl'] as String?)?.trim() ?? '',
      verifiedKeyIds: [
        for (final item in (json['verifiedKeyIds'] as List?) ?? const [])
          if (item != null && item.toString().trim().isNotEmpty)
            item.toString().trim(),
      ],
      artifactSha256: (json['artifactSha256'] as String?)?.trim() ?? '',
      stagedBytes: (json['stagedBytes'] as num?)?.toInt() ?? 0,
      totalBytes: (json['totalBytes'] as num?)?.toInt() ?? 0,
      errorCode: (json['errorCode'] as String?)?.trim() ?? '',
      productionReady: json['productionReady'] == true,
      updateAvailable: json['updateAvailable'] == true,
      restartRequired: json['restartRequired'] == true,
    );
  }

  ClientUpdateStatus copyWith({
    ClientUpdatePhase? phase,
    String? currentVersion,
    String? channel,
    String? availableVersion,
    String? releaseNotesUrl,
    List<String>? verifiedKeyIds,
    String? artifactSha256,
    int? stagedBytes,
    int? totalBytes,
    String? errorCode,
    bool? productionReady,
    bool? updateAvailable,
    bool? restartRequired,
  }) {
    return ClientUpdateStatus(
      phase: phase ?? this.phase,
      currentVersion: currentVersion ?? this.currentVersion,
      channel: channel ?? this.channel,
      availableVersion: availableVersion ?? this.availableVersion,
      releaseNotesUrl: releaseNotesUrl ?? this.releaseNotesUrl,
      verifiedKeyIds: verifiedKeyIds ?? this.verifiedKeyIds,
      artifactSha256: artifactSha256 ?? this.artifactSha256,
      stagedBytes: stagedBytes ?? this.stagedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      errorCode: errorCode ?? this.errorCode,
      productionReady: productionReady ?? this.productionReady,
      updateAvailable: updateAvailable ?? this.updateAvailable,
      restartRequired: restartRequired ?? this.restartRequired,
    );
  }
}
