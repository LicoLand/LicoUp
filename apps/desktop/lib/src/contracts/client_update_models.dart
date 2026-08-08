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
  applied,
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
    this.artifactReceiptId = '',
    this.manifestSha256 = '',
    this.targetId = '',
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
  final String artifactReceiptId;
  final String manifestSha256;
  final String targetId;
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
    final receiptValue = json['artifactReceipt'];
    final receipt = receiptValue is Map
        ? receiptValue
        : const <String, dynamic>{};
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
        'applied' => ClientUpdatePhase.applied,
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
      artifactSha256:
          (json['artifactSha256'] as String?)?.trim() ??
          (receipt['sha256'] as String?)?.trim() ??
          '',
      artifactReceiptId:
          (json['stagedArtifactId'] as String?)?.trim() ??
          (json['installedArtifactId'] as String?)?.trim() ??
          (receipt['receiptId'] as String?)?.trim() ??
          '',
      manifestSha256:
          (json['manifestSha256'] as String?)?.trim() ??
          (receipt['manifestSha256'] as String?)?.trim() ??
          '',
      targetId:
          (json['targetId'] as String?)?.trim() ??
          (receipt['targetId'] as String?)?.trim() ??
          '',
      stagedBytes: (json['stagedBytes'] as num?)?.toInt() ?? 0,
      totalBytes:
          (json['totalBytes'] as num?)?.toInt() ??
          ((json['artifact'] as Map?)?['size'] as num?)?.toInt() ??
          0,
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
    String? artifactReceiptId,
    String? manifestSha256,
    String? targetId,
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
      artifactReceiptId: artifactReceiptId ?? this.artifactReceiptId,
      manifestSha256: manifestSha256 ?? this.manifestSha256,
      targetId: targetId ?? this.targetId,
      stagedBytes: stagedBytes ?? this.stagedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      errorCode: errorCode ?? this.errorCode,
      productionReady: productionReady ?? this.productionReady,
      updateAvailable: updateAvailable ?? this.updateAvailable,
      restartRequired: restartRequired ?? this.restartRequired,
    );
  }
}
