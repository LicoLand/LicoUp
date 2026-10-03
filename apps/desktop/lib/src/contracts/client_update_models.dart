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
  unavailable,
  updateAvailable,
  downloading,
  downloaded,
  verifying,
  verified,
  applyPlanned,
  applied,
  failed,

  /// A signed artifact is verified, but the host still owns unfinished work, so
  /// maintenance admission refuses the switch. The client never clears this by
  /// itself: only a new native answer moves it back to [verified].
  blocked,
}

/// The native maintenance decision that gates one installed-state change.
///
/// This mirrors the native `AdmissionDecision` one to one, plus [unknown] for
/// an answer this client did not receive. [unknown] is the fail-closed default:
/// a client that cannot read the host decision never unlocks an update.
enum ClientUpdateAdmissionDecision {
  idle('idle'),
  blocked('blocked'),
  closed('closed'),
  unknown('');

  const ClientUpdateAdmissionDecision(this.wireName);
  final String wireName;
}

/// Which local owner reported one unfinished task.
enum ClientUpdateBlockerOwner {
  canonicalConversation('canonical-conversation'),
  adaptiveFlywheel('adaptive-flywheel'),
  unknown('');

  const ClientUpdateBlockerOwner(this.wireName);
  final String wireName;

  static ClientUpdateBlockerOwner parse(Object? value) {
    final name = value?.toString().trim() ?? '';
    for (final candidate in ClientUpdateBlockerOwner.values) {
      if (candidate != ClientUpdateBlockerOwner.unknown &&
          candidate.wireName == name) {
        return candidate;
      }
    }
    return ClientUpdateBlockerOwner.unknown;
  }
}

/// One unfinished task that blocks an install switch.
///
/// Only stable, bounded identities cross this projection: the reporting owner,
/// the owner's own kind name, the Conversation or graph it belongs to, the
/// record identity and the stored state. Payloads, paths, prompt text and raw
/// owner errors never reach the client.
final class ClientUpdateBlocker {
  const ClientUpdateBlocker({
    required this.owner,
    required this.kind,
    this.scope = '',
    this.identity = '',
    this.state = '',
  });

  final ClientUpdateBlockerOwner owner;
  final String kind;
  final String scope;
  final String identity;
  final String state;

  factory ClientUpdateBlocker.fromJson(Map<String, dynamic> json) {
    return ClientUpdateBlocker(
      owner: ClientUpdateBlockerOwner.parse(json['owner']),
      kind: _boundedClientUpdateFact(json['kind'], 64),
      scope: _boundedClientUpdateFact(json['scope'], 160),
      identity: _boundedClientUpdateFact(json['identity'], 160),
      state: _boundedClientUpdateFact(json['state'], 64),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ClientUpdateBlocker &&
          other.owner == owner &&
          other.kind == kind &&
          other.scope == scope &&
          other.identity == identity &&
          other.state == state;

  @override
  int get hashCode => Object.hash(owner, kind, scope, identity, state);
}

/// The host-wide maintenance answer behind an installed-state change.
///
/// Declared native contract: the `update status` and `update check` results may
/// carry an `admission` object shaped exactly like the native
/// `domain::work_admission::Admission` — `decision`, `blockers`, `truncated`.
/// Until a native host answers it this projection stays [unknown] and every
/// gate derived from it stays closed.
final class ClientUpdateAdmission {
  const ClientUpdateAdmission({
    required this.decision,
    this.blockers = const [],
    this.truncated = false,
    this.reasonCode = '',
  });

  /// Fail-closed default for a host that did not answer.
  const ClientUpdateAdmission.unavailable([
    this.reasonCode = 'client_update_admission_unavailable',
  ]) : decision = ClientUpdateAdmissionDecision.unknown,
       blockers = const [],
       truncated = false;

  final ClientUpdateAdmissionDecision decision;
  final List<ClientUpdateBlocker> blockers;

  /// True when the native decision reported more blockers than it listed.
  final bool truncated;

  /// Stable local reason code for an absent or refused answer.
  final String reasonCode;

  /// Whether a native answer was actually observed.
  bool get observed => decision != ClientUpdateAdmissionDecision.unknown;

  /// Whether a maintenance switch may begin now. Never true without a native
  /// answer: the client cannot approve an update on its own.
  bool get allowsMaintenance => decision == ClientUpdateAdmissionDecision.idle;

  /// The stable code a locked update reports, or empty when apply may proceed.
  String get lockReasonCode => switch (decision) {
    ClientUpdateAdmissionDecision.idle => '',
    ClientUpdateAdmissionDecision.blocked => 'client_update_admission_blocked',
    ClientUpdateAdmissionDecision.closed => 'client_update_admission_closed',
    ClientUpdateAdmissionDecision.unknown =>
      reasonCode.isEmpty ? 'client_update_admission_unavailable' : reasonCode,
  };

  /// Reads the native `admission` object, or the fail-closed default.
  static ClientUpdateAdmission fromJson(Object? value) {
    if (value is! Map) return const ClientUpdateAdmission.unavailable();
    final decision = switch ((value['decision'] ?? '').toString().trim()) {
      'idle' => ClientUpdateAdmissionDecision.idle,
      'blocked' => ClientUpdateAdmissionDecision.blocked,
      'closed' => ClientUpdateAdmissionDecision.closed,
      _ => ClientUpdateAdmissionDecision.unknown,
    };
    final blockers = <ClientUpdateBlocker>[];
    for (final item in (value['blockers'] as List?) ?? const []) {
      if (item is Map) {
        blockers.add(
          ClientUpdateBlocker.fromJson(Map<String, dynamic>.from(item)),
        );
      }
    }
    return ClientUpdateAdmission(
      decision: decision,
      blockers: List<ClientUpdateBlocker>.unmodifiable(blockers),
      truncated: value['truncated'] == true,
      reasonCode: decision == ClientUpdateAdmissionDecision.unknown
          ? 'client_update_admission_unreadable'
          : '',
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ClientUpdateAdmission &&
          other.decision == decision &&
          other.truncated == truncated &&
          other.reasonCode == reasonCode &&
          _sameBlockers(other.blockers, blockers);

  @override
  int get hashCode =>
      Object.hash(decision, truncated, reasonCode, Object.hashAll(blockers));
}

bool _sameBlockers(
  List<ClientUpdateBlocker> left,
  List<ClientUpdateBlocker> right,
) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

String _boundedClientUpdateFact(Object? value, int limit) {
  final text = value?.toString().trim() ?? '';
  if (text.length <= limit) return text;
  return text.substring(0, limit);
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
    this.admission = const ClientUpdateAdmission.unavailable(),
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

  /// The host maintenance answer behind this status.
  final ClientUpdateAdmission admission;

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
        'unavailable' => ClientUpdatePhase.unavailable,
        'updateAvailable' => ClientUpdatePhase.updateAvailable,
        'downloading' => ClientUpdatePhase.downloading,
        'downloaded' => ClientUpdatePhase.downloaded,
        'verifying' => ClientUpdatePhase.verifying,
        'verified' => ClientUpdatePhase.verified,
        'applyPlanned' => ClientUpdatePhase.applyPlanned,
        'applied' => ClientUpdatePhase.applied,
        'failed' => ClientUpdatePhase.failed,
        'blocked' => ClientUpdatePhase.blocked,
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
      admission: ClientUpdateAdmission.fromJson(json['admission']),
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
    ClientUpdateAdmission? admission,
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
      admission: admission ?? this.admission,
    );
  }
}
