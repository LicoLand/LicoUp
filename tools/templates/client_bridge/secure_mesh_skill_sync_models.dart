/// `secure_mesh.skill_sync.v1` projection layered on file-sync.
///
/// Transfer uses the file-sync substrate; install happens only after local
/// confirmation and digest validation on the receiving client.
const String secureMeshSkillSyncProtocolVersion = 'secure_mesh.skill_sync.v1';

enum SecureMeshSkillSyncStatus {
  drafting,
  transferring,
  awaitingInstall,
  installing,
  installed,
  failed,
}

final class SecureMeshSkillSyncTransfer {
  const SecureMeshSkillSyncTransfer({
    required this.id,
    required this.skillId,
    required this.version,
    required this.sourceAgentId,
    required this.targetAgentId,
    required this.packageDigest,
    required this.fileTransfer,
    required this.status,
    this.installStrategy = 'skill_hub_apply',
    this.activate = false,
    this.errorCode = '',
  });

  final String id;
  final String skillId;
  final String version;
  final String sourceAgentId;
  final String targetAgentId;
  final String packageDigest;
  final String installStrategy;
  final bool activate;
  final SecureMeshFileSyncTransfer fileTransfer;
  final SecureMeshSkillSyncStatus status;
  final String errorCode;

  Map<String, dynamic> toManifest() {
    return {
      'protocolVersion': secureMeshSkillSyncProtocolVersion,
      'skillId': skillId,
      'version': version,
      'sourceAgentId': sourceAgentId,
      'targetAgentId': targetAgentId,
      'packageDigest': packageDigest,
      'installStrategy': installStrategy,
      'activate': activate,
      'file': fileTransfer.toManifest(),
    };
  }

  SecureMeshSkillSyncTransfer copyWith({
    String? id,
    String? skillId,
    String? version,
    String? sourceAgentId,
    String? targetAgentId,
    String? packageDigest,
    String? installStrategy,
    bool? activate,
    SecureMeshFileSyncTransfer? fileTransfer,
    SecureMeshSkillSyncStatus? status,
    String? errorCode,
  }) {
    return SecureMeshSkillSyncTransfer(
      id: id ?? this.id,
      skillId: skillId ?? this.skillId,
      version: version ?? this.version,
      sourceAgentId: sourceAgentId ?? this.sourceAgentId,
      targetAgentId: targetAgentId ?? this.targetAgentId,
      packageDigest: packageDigest ?? this.packageDigest,
      installStrategy: installStrategy ?? this.installStrategy,
      activate: activate ?? this.activate,
      fileTransfer: fileTransfer ?? this.fileTransfer,
      status: status ?? this.status,
      errorCode: errorCode ?? this.errorCode,
    );
  }
}
