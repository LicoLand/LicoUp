import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:licoup/src/platform/storage/client_workspace_manifest.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

export 'package:licoup/src/platform/storage/client_workspace_manifest.dart'
    show ClientWorkspaceManifest, ClientWorkspaceManifestStore;

final Object _appManagedWriterZoneKey = Object();

enum DataHomeSelectionSource {
  explicitEnvironment,
  legacyEnvironment,
  saved,
  defaultHome,
  mobileSandbox,
  testOverride,
}

final class DataHomeSelection {
  const DataHomeSelection({required this.path, required this.source});

  final String path;
  final DataHomeSelectionSource source;
}

final class MissingSavedDataHome implements Exception {
  const MissingSavedDataHome(this.path);

  final String path;

  @override
  String toString() => 'saved_data_home_unavailable';
}

class PortableDataRoot {
  static const productDirectoryName = 'LicoUp';
  static const portableDataDirectoryName = 'portable-data';

  /// Desktop state lives in a home-directory dot folder alongside other agent
  /// state namespaces like `.claude` and `.codex`.
  static const homeStateDirectoryName = '.lico-up';

  PortableDataRoot({
    Directory? dataDirectoryOverride,
    Map<String, String>? environmentOverride,
    bool? mobileRuntimeOverride,
    Future<Directory> Function()? applicationSupportDirectoryResolver,
    ClientWorkspaceManifestStore? workspaceManifestStore,
  }) : _dataDirectoryOverride = dataDirectoryOverride,
       _environmentOverride = environmentOverride,
       _mobileRuntimeOverride = mobileRuntimeOverride,
       _applicationSupportDirectoryResolver =
           applicationSupportDirectoryResolver ??
           getApplicationSupportDirectory,
       _workspaceManifestStore =
           workspaceManifestStore ?? ClientWorkspaceManifestStore();

  final Directory? _dataDirectoryOverride;
  final Map<String, String>? _environmentOverride;
  final bool? _mobileRuntimeOverride;
  final Future<Directory> Function() _applicationSupportDirectoryResolver;
  final ClientWorkspaceManifestStore _workspaceManifestStore;
  Directory? _cachedDataDir;
  DataHomeSelection? _cachedSelection;
  bool _acceptAppManagedWrites = true;
  int _activeAppManagedWrites = 0;
  Completer<void>? _appManagedWritesDrained;

  /// Drop the macOS data-volume firmlink prefix so a home path and the same
  /// path under that prefix classify as the same location.
  static const macosDataVolumePrefix =
      '/System'
      '/Volumes'
      '/Data';

  static String stripMacosDataVolume(String path) {
    const prefix = macosDataVolumePrefix;
    if (path == prefix) {
      return '/';
    }
    if (path.startsWith('$prefix/')) {
      return path.substring(prefix.length);
    }
    return path;
  }

  Future<Directory> dataDirectory() async {
    final selection = await dataHomeSelection();
    final directory = _cachedDataDir ?? Directory(selection.path);
    if (selection.source == DataHomeSelectionSource.saved &&
        !await directory.exists()) {
      throw MissingSavedDataHome(selection.path);
    }
    if (_cachedDataDir != null) return _cachedDataDir!;
    _cachedDataDir = await _prepareDataDirectory(directory);
    return _cachedDataDir!;
  }

  Future<File> bootInstanceLockFile() async {
    if (_dataDirectoryOverride != null || _isMobileRuntime) {
      final directory = await clientDirectory();
      return File(p.join(directory.path, 'client.instance.lock'));
    }
    return File(
      p.join(_dataHomeLocatorFile().parent.path, 'client.instance.lock'),
    );
  }

  Future<DataHomeSelection> dataHomeSelection() async =>
      _cachedSelection ??= await _resolveDataHomeSelection();

  Future<bool> missingSavedDataHome() async {
    final selection = await dataHomeSelection();
    return selection.source == DataHomeSelectionSource.saved &&
        !await Directory(selection.path).exists();
  }

  Future<DataHomeSelection> _resolveDataHomeSelection() async {
    if (_dataDirectoryOverride != null) {
      return DataHomeSelection(
        path: p.normalize(p.absolute(_dataDirectoryOverride.path)),
        source: DataHomeSelectionSource.testOverride,
      );
    }
    // Mobile state stays in the application container and ignores desktop
    // environment and locator settings.
    if (_isMobileRuntime) {
      final directory = await _systemDataDirectory();
      return DataHomeSelection(
        path: p.normalize(p.absolute(directory.path)),
        source: DataHomeSelectionSource.mobileSandbox,
      );
    }

    final explicit = _usableEnvironmentPath(_environment['LICOUP_HOME']);
    if (explicit != null) {
      return DataHomeSelection(
        path: p.normalize(p.absolute(explicit)),
        source: DataHomeSelectionSource.explicitEnvironment,
      );
    }
    final legacy = _usableEnvironmentPath(_environment['LICOUP_PORTABLE_DIR']);
    if (legacy != null) {
      return DataHomeSelection(
        path: p.normalize(p.absolute(legacy)),
        source: DataHomeSelectionSource.legacyEnvironment,
      );
    }
    final saved = await _readSavedDataHome();
    if (saved != null) {
      return DataHomeSelection(
        path: p.normalize(p.absolute(saved)),
        source: DataHomeSelectionSource.saved,
      );
    }
    final directory = await _systemDataDirectory();
    return DataHomeSelection(
      path: p.normalize(p.absolute(directory.path)),
      source: DataHomeSelectionSource.defaultHome,
    );
  }

  String? _usableEnvironmentPath(String? value) {
    final trimmed = value?.trim() ?? '';
    if (trimmed.isEmpty ||
        trimmed.startsWith(r'$') ||
        trimmed.contains(r'${') ||
        trimmed.contains(r'${env:')) {
      return null;
    }
    return trimmed;
  }

  Future<String?> _readSavedDataHome() async {
    final locator = _dataHomeLocatorFile();
    final type = await FileSystemEntity.type(locator.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file) {
      throw const FormatException('saved_data_home_invalid');
    }
    final bytes = <int>[];
    await for (final chunk in locator.openRead(0, 32 * 1024 + 1)) {
      bytes.addAll(chunk);
      if (bytes.length > 32 * 1024) {
        throw const FormatException('saved_data_home_invalid');
      }
    }
    final value = utf8.decode(bytes).trim();
    if (value.isEmpty || !p.isAbsolute(value)) {
      throw const FormatException('saved_data_home_invalid');
    }
    return value;
  }

  File _dataHomeLocatorFile() {
    final home = PortableDataRoot.stripMacosDataVolume(_userHomePath);
    if (home.isEmpty) {
      throw StateError('desktop state root requires HOME');
    }
    if (Platform.isMacOS) {
      return File(
        p.join(home, 'Library', 'Application Support', 'LicoUp', 'data-home'),
      );
    }
    if (Platform.isWindows) {
      final appData = (_environment['APPDATA'] ?? '').trim();
      return File(
        p.join(
          appData.isEmpty ? p.join(home, 'AppData', 'Roaming') : appData,
          'LicoUp',
          'data-home',
        ),
      );
    }
    final xdg = (_environment['XDG_CONFIG_HOME'] ?? '').trim();
    return File(
      p.join(
        xdg.isNotEmpty && p.isAbsolute(xdg) ? xdg : p.join(home, '.config'),
        'licoup',
        'data-home',
      ),
    );
  }

  Future<Directory> clientDirectory() async {
    final dataDir = await dataDirectory();
    final directory = Directory(p.join(dataDir.path, 'client-state'));
    await withAppManagedWriter(() => directory.create(recursive: true));
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

  Future<ClientWorkspaceManifest> loadWorkspaceManifest() =>
      withAppManagedWriter(() async {
        final directory = await dataDirectory();
        return _workspaceManifestStore.loadOrCreate(directory);
      });

  /// Runs one app-owned write under this composition's local root admission.
  /// Relocation closes admission and waits for all accepted writes before the
  /// native process releases its root lease and starts copying.
  Future<T> withAppManagedWriter<T>(Future<T> Function() operation) {
    if (identical(Zone.current[_appManagedWriterZoneKey], this)) {
      return operation();
    }
    if (!_acceptAppManagedWrites) {
      return Future<T>.error(StateError('data_home_writers_quiescing'));
    }
    _activeAppManagedWrites += 1;
    return runZoned<Future<T>>(
      () => _runAppManagedWriter(operation),
      zoneValues: <Object, Object>{_appManagedWriterZoneKey: this},
    );
  }

  Future<T> _runAppManagedWriter<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } finally {
      _activeAppManagedWrites -= 1;
      if (!_acceptAppManagedWrites &&
          _activeAppManagedWrites == 0 &&
          !(_appManagedWritesDrained?.isCompleted ?? true)) {
        _appManagedWritesDrained!.complete();
      }
    }
  }

  /// Permanently closes writes for this composition and waits for accepted
  /// operations. A replacement composition owns a new admission gate.
  Future<void> stopAppManagedWritersAndDrain() {
    _acceptAppManagedWrites = false;
    if (_activeAppManagedWrites == 0) return Future<void>.value();
    return (_appManagedWritesDrained ??= Completer<void>()).future;
  }

  Future<Directory> _prepareDataDirectory(Directory directory) async {
    await withAppManagedWriter(() => directory.create(recursive: true));
    return directory;
  }

  Map<String, String> get _environment =>
      _environmentOverride ?? Platform.environment;

  String get _userHomePath {
    final home = (_environment['HOME'] ?? _environment['USERPROFILE'] ?? '')
        .trim();
    if (home.isNotEmpty) return home;
    final drive = (_environment['HOMEDRIVE'] ?? '').trim();
    final path = (_environment['HOMEPATH'] ?? '').trim();
    return drive.isNotEmpty && path.isNotEmpty ? p.join(drive, path) : '';
  }

  bool get _isMobileRuntime =>
      _mobileRuntimeOverride ?? (Platform.isAndroid || Platform.isIOS);

  Future<Directory> _systemDataDirectory() async {
    if (!_isMobileRuntime) {
      final home = PortableDataRoot.stripMacosDataVolume(_userHomePath);
      if (home.isEmpty) {
        throw StateError('desktop state root requires HOME');
      }
      return Directory(p.join(home, homeStateDirectoryName));
    }
    final appSupport = await _applicationSupportDirectoryResolver();
    return Directory(
      p.join(appSupport.path, productDirectoryName, portableDataDirectoryName),
    );
  }
}
