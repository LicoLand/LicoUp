import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'client_workspace_manifest.dart';

class PortableDataRoot {
  PortableDataRoot({
    Directory? dataDirectoryOverride,
    Map<String, String>? environmentOverride,
    String? resolvedExecutableOverride,
    Future<Directory> Function()? applicationSupportDirectoryResolver,
  }) : _dataDirectoryOverride = dataDirectoryOverride,
       _environmentOverride = environmentOverride,
       _resolvedExecutableOverride = resolvedExecutableOverride,
       _applicationSupportDirectoryResolver =
           applicationSupportDirectoryResolver ??
           getApplicationSupportDirectory;

  static const String _workspaceManifestFileName = '.lico-workspace.json';

  final Directory? _dataDirectoryOverride;
  final Map<String, String>? _environmentOverride;
  final String? _resolvedExecutableOverride;
  final Future<Directory> Function() _applicationSupportDirectoryResolver;
  Directory? _cachedDataDir;

  Future<Directory> dataDirectory() async {
    if (_cachedDataDir != null) {
      return _cachedDataDir!;
    }

    if (_dataDirectoryOverride != null) {
      _cachedDataDir = await _prepareDataDirectory(_dataDirectoryOverride);
      return _cachedDataDir!;
    }

    final executableDirectory = File(_resolvedExecutable).parent;
    if (_bundledMacAppDirectory(executableDirectory) != null) {
      _cachedDataDir = await _prepareDataDirectory(
        await _systemDataDirectory(),
      );
      return _cachedDataDir!;
    }

    final override = _environment['LICO_PORTABLE_DIR'];
    if (override != null && override.trim().isNotEmpty) {
      _cachedDataDir = await _prepareDataDirectory(Directory(override.trim()));
      return _cachedDataDir!;
    }

    final portableDirectory = _portableDirectoryForLooseExecutable(
      executableDirectory,
    );
    if (await _tryUseDirectory(portableDirectory)) {
      _cachedDataDir = await _prepareDataDirectory(portableDirectory);
      return _cachedDataDir!;
    }

    _cachedDataDir = await _prepareDataDirectory(await _systemDataDirectory());
    return _cachedDataDir!;
  }

  Future<Directory> futureClientDirectory() async {
    final dataDir = await dataDirectory();
    final directory = Directory(p.join(dataDir.path, 'future-client'));
    await directory.create(recursive: true);
    return directory;
  }

  Future<File> activityLogFile() async {
    final root = await futureClientDirectory();
    return File(p.join(root.path, 'activity', 'activity.jsonl'));
  }

  Future<Directory> snapshotDirectory() async {
    final root = await futureClientDirectory();
    return Directory(p.join(root.path, 'snapshots'));
  }

  Future<ClientWorkspaceManifest> loadWorkspaceManifest() async {
    final directory = await dataDirectory();
    return _loadOrCreateWorkspaceManifest(directory);
  }

  Future<Directory> _prepareDataDirectory(Directory directory) async {
    await directory.create(recursive: true);
    await _loadOrCreateWorkspaceManifest(directory);
    return directory;
  }

  Future<ClientWorkspaceManifest> _loadOrCreateWorkspaceManifest(
    Directory directory,
  ) async {
    final file = File(p.join(directory.path, _workspaceManifestFileName));
    if (await file.exists()) {
      ClientWorkspaceManifest? manifest;
      try {
        final raw = await file.readAsString();
        manifest = ClientWorkspaceManifest.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
      } catch (_) {
        final corruptFile = File(
          '${file.path}.corrupt.${DateTime.now().toUtc().microsecondsSinceEpoch}',
        );
        await file.rename(corruptFile.path);
      }
      if (manifest != null) {
        if (manifest.appId != ClientWorkspaceManifest.licoClientAppId ||
            manifest.schemaVersion >
                ClientWorkspaceManifest.currentSchemaVersion ||
            manifest.workspaceId.isEmpty) {
          throw StateError('不是 LicoLite 客户端工作空间：${directory.path}');
        }
        final touched = manifest.touch();
        await _writeJsonAtomically(file, touched.toJson());
        return touched;
      }
    }

    final manifest = ClientWorkspaceManifest.create();
    await _writeJsonAtomically(file, manifest.toJson());
    return manifest;
  }

  Map<String, String> get _environment =>
      _environmentOverride ?? Platform.environment;

  String get _resolvedExecutable =>
      _resolvedExecutableOverride ?? Platform.resolvedExecutable;

  Future<Directory> _systemDataDirectory() async {
    final appSupport = await _applicationSupportDirectoryResolver();
    return Directory(p.join(appSupport.path, 'portable-data'));
  }

  Directory? _bundledMacAppDirectory(Directory executableDirectory) {
    final contentsDirectory = executableDirectory.parent;
    final appBundleDirectory = contentsDirectory.parent;
    final isBundledMacExecutable =
        p.basename(executableDirectory.path) == 'MacOS' &&
        p.basename(contentsDirectory.path) == 'Contents' &&
        p.extension(appBundleDirectory.path) == '.app';

    if (isBundledMacExecutable) {
      return appBundleDirectory;
    }

    return null;
  }

  Directory _portableDirectoryForLooseExecutable(
    Directory executableDirectory,
  ) {
    return Directory(p.join(executableDirectory.path, 'portable-data'));
  }

  Future<bool> _tryUseDirectory(Directory directory) async {
    try {
      await directory.create(recursive: true);
      final probe = File(p.join(directory.path, '.lico-probe'));
      await probe.writeAsString('ok');
      await probe.delete();
      return true;
    } catch (_) {
      return false;
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
          '.${p.basename(file.path)}.$pid.${DateTime.now().toUtc().microsecondsSinceEpoch}.tmp',
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
