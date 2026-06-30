part of 'portable_data_root.dart';

class ClientWorkspaceManifest {
  const ClientWorkspaceManifest({
    required this.schemaVersion,
    required this.appId,
    required this.workspaceId,
    required this.createdAt,
    required this.updatedAt,
  });

  static const currentSchemaVersion = 1;
  static const licoClientAppId = 'lico-client';

  final int schemaVersion;
  final String appId;
  final String workspaceId;
  final String createdAt;
  final String updatedAt;

  factory ClientWorkspaceManifest.create() {
    final now = DateTime.now().toUtc().toIso8601String();
    final seed = '$now:$pid:${Directory.current.path}';
    final workspaceId = sha256.convert(utf8.encode(seed)).toString();
    return ClientWorkspaceManifest(
      schemaVersion: currentSchemaVersion,
      appId: licoClientAppId,
      workspaceId: workspaceId,
      createdAt: now,
      updatedAt: now,
    );
  }

  factory ClientWorkspaceManifest.fromJson(Map<String, dynamic> json) {
    return ClientWorkspaceManifest(
      schemaVersion: (json['schemaVersion'] as num?)?.toInt() ?? 0,
      appId: (json['appId'] ?? '').toString(),
      workspaceId: (json['workspaceId'] ?? '').toString(),
      createdAt: (json['createdAt'] ?? '').toString(),
      updatedAt: (json['updatedAt'] ?? '').toString(),
    );
  }

  ClientWorkspaceManifest touch() {
    return ClientWorkspaceManifest(
      schemaVersion: schemaVersion,
      appId: appId,
      workspaceId: workspaceId,
      createdAt: createdAt,
      updatedAt: DateTime.now().toUtc().toIso8601String(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'schemaVersion': schemaVersion,
      'appId': appId,
      'workspaceId': workspaceId,
      'createdAt': createdAt,
      'updatedAt': updatedAt,
    };
  }
}
