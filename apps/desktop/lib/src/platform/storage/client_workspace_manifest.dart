import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

typedef ClientWorkspaceManifestClock = DateTime Function();
typedef ClientWorkspaceIdFactory = String Function(DateTime timestamp);

class ClientWorkspaceManifest {
  const ClientWorkspaceManifest({
    required this.schemaVersion,
    required this.appId,
    required this.workspaceId,
    required this.createdAt,
    required this.updatedAt,
  });

  static const currentSchemaVersion = 1;
  static const licoUpAppId = 'licoup-client';

  final int schemaVersion;
  final String appId;
  final String workspaceId;
  final String createdAt;
  final String updatedAt;

  factory ClientWorkspaceManifest.create({
    DateTime? timestamp,
    String? workspaceId,
  }) {
    final now = (timestamp ?? DateTime.now()).toUtc();
    final serializedNow = now.toIso8601String();
    return ClientWorkspaceManifest(
      schemaVersion: currentSchemaVersion,
      appId: licoUpAppId,
      workspaceId: workspaceId ?? _newWorkspaceId(now),
      createdAt: serializedNow,
      updatedAt: serializedNow,
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

  ClientWorkspaceManifest touch({DateTime? timestamp}) {
    return ClientWorkspaceManifest(
      schemaVersion: schemaVersion,
      appId: appId,
      workspaceId: workspaceId,
      createdAt: createdAt,
      updatedAt: (timestamp ?? DateTime.now()).toUtc().toIso8601String(),
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

class ClientWorkspaceManifestStore {
  ClientWorkspaceManifestStore({
    ClientWorkspaceManifestClock? clock,
    ClientWorkspaceIdFactory? workspaceIdFactory,
  }) : _clock = clock ?? _utcNow,
       _workspaceIdFactory = workspaceIdFactory ?? _newWorkspaceId;

  static const fileName = '.licoup-workspace.json';

  final ClientWorkspaceManifestClock _clock;
  final ClientWorkspaceIdFactory _workspaceIdFactory;

  Future<ClientWorkspaceManifest> loadOrCreate(Directory directory) async {
    final file = File(p.join(directory.path, fileName));
    if (await file.exists()) {
      final manifest = await _readOrQuarantine(file);
      if (manifest != null) {
        if (!_isCompatible(manifest)) {
          throw StateError('client_workspace_manifest_incompatible');
        }
        final touched = manifest.touch(timestamp: _clock());
        await _writeJsonAtomically(file, touched.toJson());
        return touched;
      }
    }

    final now = _clock().toUtc();
    final manifest = ClientWorkspaceManifest.create(
      timestamp: now,
      workspaceId: _workspaceIdFactory(now),
    );
    await _writeJsonAtomically(file, manifest.toJson());
    return manifest;
  }

  bool _isCompatible(ClientWorkspaceManifest manifest) {
    return manifest.appId == ClientWorkspaceManifest.licoUpAppId &&
        manifest.schemaVersion <=
            ClientWorkspaceManifest.currentSchemaVersion &&
        manifest.workspaceId.isNotEmpty;
  }

  Future<ClientWorkspaceManifest?> _readOrQuarantine(File file) async {
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) {
        throw const FormatException('workspace_manifest_not_an_object');
      }
      return ClientWorkspaceManifest.fromJson(
        Map<String, dynamic>.from(decoded),
      );
    } catch (_) {
      final suffix = _clock().toUtc().microsecondsSinceEpoch;
      await file.rename('${file.path}.corrupt.$suffix');
      return null;
    }
  }

  Future<void> _writeJsonAtomically(File file, Object? value) {
    return _writeTextAtomically(
      file,
      const JsonEncoder.withIndent('  ').convert(value),
    );
  }

  Future<void> _writeTextAtomically(File file, String contents) async {
    await file.parent.create(recursive: true);
    final lock = File(
      p.join(file.parent.path, '${p.basename(file.path)}.lock'),
    );
    final lockHandle = await lock.open(mode: FileMode.write);
    try {
      await lockHandle.lock(FileLock.exclusive);
      final temp = File(
        p.join(
          file.parent.path,
          '.${p.basename(file.path)}.$pid.${_clock().toUtc().microsecondsSinceEpoch}.tmp',
        ),
      );
      await temp.writeAsString(contents, flush: true);
      await temp.rename(file.path);
    } finally {
      try {
        await lockHandle.unlock();
      } finally {
        await lockHandle.close();
      }
    }
  }
}

DateTime _utcNow() => DateTime.now().toUtc();

String _newWorkspaceId(DateTime timestamp) {
  final nonce = Random.secure().nextInt(1 << 32);
  final seed = '${timestamp.toUtc().microsecondsSinceEpoch}:$pid:$nonce';
  return sha256.convert(utf8.encode(seed)).toString();
}
