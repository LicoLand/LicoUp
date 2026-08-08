import 'dart:io';

import 'package:licoup/src/platform/storage/client_workspace_manifest.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

export 'package:licoup/src/platform/storage/client_workspace_manifest.dart'
    show ClientWorkspaceManifest, ClientWorkspaceManifestStore;

class PortableDataRoot {
  static const productDirectoryName = 'LicoUp';
  static const portableDataDirectoryName = 'portable-data';

  /// Desktop state lives in a home-directory dot folder alongside other agent
  /// state namespaces like `.claude` and `.codex`.
  static const homeStateDirectoryName = '.lico-up';

  PortableDataRoot({
    Directory? dataDirectoryOverride,
    Map<String, String>? environmentOverride,
    String? resolvedExecutableOverride,
    bool? mobileRuntimeOverride,
    Future<Directory> Function()? applicationSupportDirectoryResolver,
    ClientWorkspaceManifestStore? workspaceManifestStore,
  }) : _dataDirectoryOverride = dataDirectoryOverride,
       _environmentOverride = environmentOverride,
       _resolvedExecutableOverride = resolvedExecutableOverride,
       _mobileRuntimeOverride = mobileRuntimeOverride,
       _applicationSupportDirectoryResolver =
           applicationSupportDirectoryResolver ??
           getApplicationSupportDirectory,
       _workspaceManifestStore =
           workspaceManifestStore ?? ClientWorkspaceManifestStore();

  final Directory? _dataDirectoryOverride;
  final Map<String, String>? _environmentOverride;
  final String? _resolvedExecutableOverride;
  final bool? _mobileRuntimeOverride;
  final Future<Directory> Function() _applicationSupportDirectoryResolver;
  final ClientWorkspaceManifestStore _workspaceManifestStore;
  Directory? _cachedDataDir;

  Future<Directory> dataDirectory() async {
    if (_cachedDataDir != null) {
      return _cachedDataDir!;
    }

    if (_dataDirectoryOverride != null) {
      _cachedDataDir = await _prepareDataDirectory(_dataDirectoryOverride);
      return _cachedDataDir!;
    }

    // Mobile application bundles are immutable release artifacts. Runtime
    // state belongs in the platform data container even when the simulator's
    // installed bundle happens to be writable.
    if (_isMobileRuntime) {
      _cachedDataDir = await _prepareDataDirectory(
        await _systemDataDirectory(),
      );
      return _cachedDataDir!;
    }

    final executableDirectory = File(_resolvedExecutable).parent;
    if (_bundledMacAppDirectory(executableDirectory) != null) {
      _cachedDataDir = await _prepareDataDirectory(
        await _systemDataDirectory(),
      );
      return _cachedDataDir!;
    }

    final override = _environment['LICOUP_PORTABLE_DIR'];
    if (override != null && override.trim().isNotEmpty) {
      _cachedDataDir = await _prepareDataDirectory(Directory(override.trim()));
      return _cachedDataDir!;
    }

    _cachedDataDir = await _prepareDataDirectory(await _systemDataDirectory());
    return _cachedDataDir!;
  }

  Future<Directory> clientDirectory() async {
    final dataDir = await dataDirectory();
    final directory = Directory(p.join(dataDir.path, 'client-state'));
    await directory.create(recursive: true);
    return directory;
  }

  Future<File> activityLogFile() async {
    final root = await clientDirectory();
    return File(p.join(root.path, 'activity', 'activity.jsonl'));
  }

  Future<Directory> snapshotDirectory() async {
    final root = await clientDirectory();
    return Directory(p.join(root.path, 'snapshots'));
  }

  Future<ClientWorkspaceManifest> loadWorkspaceManifest() async {
    final directory = await dataDirectory();
    return _workspaceManifestStore.loadOrCreate(directory);
  }

  Future<Directory> _prepareDataDirectory(Directory directory) async {
    await directory.create(recursive: true);
    await _workspaceManifestStore.loadOrCreate(directory);
    return directory;
  }

  Map<String, String> get _environment =>
      _environmentOverride ?? Platform.environment;

  String get _resolvedExecutable =>
      _resolvedExecutableOverride ?? Platform.resolvedExecutable;

  bool get _isMobileRuntime =>
      _mobileRuntimeOverride ?? (Platform.isAndroid || Platform.isIOS);

  Future<Directory> _systemDataDirectory() async {
    if (!_isMobileRuntime) {
      final home = (_environment['HOME'] ?? _environment['USERPROFILE'] ?? '')
          .trim();
      if (home.isNotEmpty) {
        return Directory(p.join(home, homeStateDirectoryName));
      }
    }
    final appSupport = await _applicationSupportDirectoryResolver();
    return Directory(
      p.join(appSupport.path, productDirectoryName, portableDataDirectoryName),
    );
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
}
