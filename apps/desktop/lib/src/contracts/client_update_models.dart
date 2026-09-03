/// Public GitHub repository the signed client-update path already uses.
const kClientUpdateGithubRepo = 'LicoLand/LicoUp';

/// Public GitHub releases origin for [kClientUpdateGithubRepo].
const kClientUpdateGithubReleasesUrl =
    'https://github.com/LicoLand/LicoUp/releases';

/// Returns the public GitHub release origin, or a specific signed release URL
/// when native check already returned one. Rejects credentialed or query URLs.
String clientUpdatePublicSourceAddress({
  String repo = kClientUpdateGithubRepo,
  String githubReleaseUrl = '',
}) {
  final release = githubReleaseUrl.trim();
  final releaseUri = Uri.tryParse(release);
  if (releaseUri != null &&
      releaseUri.scheme == 'https' &&
      releaseUri.host == 'github.com' &&
      releaseUri.userInfo.isEmpty &&
      releaseUri.query.isEmpty &&
      releaseUri.fragment.isEmpty) {
    return release;
  }
  final normalized = repo.trim().isEmpty
      ? kClientUpdateGithubRepo
      : repo.trim();
  return 'https://github.com/$normalized/releases';
}

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

enum ReleaseTrack {
  nightly('nightly'),
  stable('stable');

  const ReleaseTrack(this.wireName);
  final String wireName;

  static ReleaseTrack parse(Object? value) => switch (value) {
    'nightly' => ReleaseTrack.nightly,
    'stable' => ReleaseTrack.stable,
    _ => throw FormatException('Unsupported client release track: $value'),
  };
}

final class ClientUpdateStatus {
  const ClientUpdateStatus({
    required this.phase,
    required this.runningVersion,
    required this.runningReleaseTrack,
    required this.targetReleaseTrack,
    this.availableVersion = '',
    this.releaseNotesUrl = '',
    this.githubReleaseUrl = '',
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
  final String runningVersion;
  final ReleaseTrack runningReleaseTrack;
  final ReleaseTrack targetReleaseTrack;
  final String availableVersion;
  final String releaseNotesUrl;
  final String githubReleaseUrl;
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
    String runningVersion = '',
    ReleaseTrack runningReleaseTrack = ReleaseTrack.nightly,
    ReleaseTrack targetReleaseTrack = ReleaseTrack.nightly,
  }) {
    return ClientUpdateStatus(
      phase: ClientUpdatePhase.idle,
      runningVersion: runningVersion,
      runningReleaseTrack: runningReleaseTrack,
      targetReleaseTrack: targetReleaseTrack,
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
      runningVersion: (json['runningVersion'] as String?)?.trim() ?? '',
      runningReleaseTrack: ReleaseTrack.parse(json['runningReleaseTrack']),
      targetReleaseTrack: ReleaseTrack.parse(json['targetReleaseTrack']),
      availableVersion: (json['availableVersion'] as String?)?.trim() ?? '',
      releaseNotesUrl: (json['releaseNotesUrl'] as String?)?.trim() ?? '',
      githubReleaseUrl: (json['githubReleaseUrl'] as String?)?.trim() ?? '',
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
      totalBytes: (json['totalBytes'] as num?)?.toInt() ?? 0,
      errorCode: (json['errorCode'] as String?)?.trim() ?? '',
      productionReady: json['productionReady'] == true,
      updateAvailable: json['updateAvailable'] == true,
      restartRequired: json['restartRequired'] == true,
    );
  }

  ClientUpdateStatus copyWith({
    ClientUpdatePhase? phase,
    String? runningVersion,
    ReleaseTrack? runningReleaseTrack,
    ReleaseTrack? targetReleaseTrack,
    String? availableVersion,
    String? releaseNotesUrl,
    String? githubReleaseUrl,
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
      runningVersion: runningVersion ?? this.runningVersion,
      runningReleaseTrack: runningReleaseTrack ?? this.runningReleaseTrack,
      targetReleaseTrack: targetReleaseTrack ?? this.targetReleaseTrack,
      availableVersion: availableVersion ?? this.availableVersion,
      releaseNotesUrl: releaseNotesUrl ?? this.releaseNotesUrl,
      githubReleaseUrl: githubReleaseUrl ?? this.githubReleaseUrl,
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
