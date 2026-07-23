/// Local Secure Mesh file-sync transfer projection for the client GUI.
///
/// Holds only the fields needed for picker → destination → confirmation UX.
/// Wire ciphertext and absolute source paths stay out of status surfaces.
enum SecureMeshFileSyncStatus {
  drafting,
  evaluating,
  awaitingConfirmation,
  confirmed,
  rejected,
  failed,
}

final class SecureMeshFileSyncTransfer {
  const SecureMeshFileSyncTransfer({
    required this.id,
    required this.fileName,
    required this.totalSize,
    required this.chunkCount,
    required this.destinationRoot,
    required this.status,
    this.mimeType = 'application/octet-stream',
    this.relativePath = '.',
    this.conflictPolicy = 'fail_if_exists',
    this.errorCode = '',
    this.chunkSize = 0,
    this.fileId = '',
  });

  final String id;
  final String fileId;
  final String fileName;
  final String mimeType;
  final String relativePath;
  final String destinationRoot;
  final String conflictPolicy;
  final int totalSize;
  final int chunkSize;
  final int chunkCount;
  final SecureMeshFileSyncStatus status;
  final String errorCode;

  bool get awaitsConfirmation =>
      status == SecureMeshFileSyncStatus.awaitingConfirmation;

  SecureMeshFileSyncTransfer copyWith({
    String? id,
    String? fileId,
    String? fileName,
    String? mimeType,
    String? relativePath,
    String? destinationRoot,
    String? conflictPolicy,
    int? totalSize,
    int? chunkSize,
    int? chunkCount,
    SecureMeshFileSyncStatus? status,
    String? errorCode,
  }) {
    return SecureMeshFileSyncTransfer(
      id: id ?? this.id,
      fileId: fileId ?? this.fileId,
      fileName: fileName ?? this.fileName,
      mimeType: mimeType ?? this.mimeType,
      relativePath: relativePath ?? this.relativePath,
      destinationRoot: destinationRoot ?? this.destinationRoot,
      conflictPolicy: conflictPolicy ?? this.conflictPolicy,
      totalSize: totalSize ?? this.totalSize,
      chunkSize: chunkSize ?? this.chunkSize,
      chunkCount: chunkCount ?? this.chunkCount,
      status: status ?? this.status,
      errorCode: errorCode ?? this.errorCode,
    );
  }

  Map<String, dynamic> toManifest() {
    return {
      'fileId': fileId.isEmpty ? id : fileId,
      'fileName': fileName,
      'mimeType': mimeType,
      'relativePath': relativePath,
      'totalSize': totalSize,
      'chunkSize': chunkSize,
      'chunkCount': chunkCount,
    };
  }
}

const int secureMeshFileSyncDefaultChunkSize = 8 * 1024 * 1024;

int secureMeshFileSyncChunkCount(int totalSize, int chunkSize) {
  if (totalSize <= 0 || chunkSize <= 0) {
    return 0;
  }
  return (totalSize + chunkSize - 1) ~/ chunkSize;
}
