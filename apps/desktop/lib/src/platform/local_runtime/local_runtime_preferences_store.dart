import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:flutter_client/src/contracts/local_runtime_preferences.dart';
import 'package:flutter_client/src/platform/storage/portable_data_root.dart';

class PlatformLocalRuntimePreferencesStore
    implements LocalRuntimePreferencesStore {
  const PlatformLocalRuntimePreferencesStore({
    Map<String, String>? environmentOverride,
    String? currentDirectoryOverride,
  }) : _environmentOverride = environmentOverride,
       _currentDirectoryOverride = currentDirectoryOverride;

  static const _fileName = 'local-runtime-preferences.json';

  final Map<String, String>? _environmentOverride;
  final String? _currentDirectoryOverride;

  @override
  Future<LocalRuntimePreferences> load(Object portableData) async {
    final file = await _preferencesFile(portableData);
    if (await file.exists()) {
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map<String, dynamic>) {
          return _normalize(LocalRuntimePreferences.fromJson(decoded));
        }
        if (decoded is Map) {
          return _normalize(
            LocalRuntimePreferences.fromJson(
              Map<String, dynamic>.from(decoded),
            ),
          );
        }
      } catch (_) {
        return _defaultPreferences();
      }
    }
    return _defaultPreferences();
  }

  @override
  Future<void> save(
    Object portableData,
    LocalRuntimePreferences preferences,
  ) async {
    final file = await _preferencesFile(portableData);
    await file.parent.create(recursive: true);
    final temp = File(
      p.join(
        file.parent.path,
        '.${p.basename(file.path)}.${DateTime.now().toUtc().microsecondsSinceEpoch}.tmp',
      ),
    );
    await temp.writeAsString(
      const JsonEncoder.withIndent(
        '  ',
      ).convert(_normalize(preferences).toJson()),
      flush: true,
    );
    await temp.rename(file.path);
  }

  LocalRuntimePreferences _defaultPreferences() {
    final sourceRoot = _sourceRootFromEnvironment() ?? _discoverSourceRoot();
    return _normalize(
      LocalRuntimePreferences(sourceRoot: sourceRoot ?? '', presetConfig: ''),
    );
  }

  LocalRuntimePreferences _normalize(LocalRuntimePreferences preferences) {
    return preferences.normalized(
      presetConfigForSourceRoot: _presetForSourceRoot,
    );
  }

  String? _sourceRootFromEnvironment() {
    final value =
        (_environmentOverride ?? Platform.environment)['LICO_SOURCE_ROOT'];
    if (value == null || value.trim().isEmpty) {
      return null;
    }
    return value.trim();
  }

  String? _discoverSourceRoot() {
    var directory = Directory(
      _currentDirectoryOverride ?? Directory.current.path,
    );
    while (true) {
      final presetFile = File(
        p.join(directory.path, LocalRuntimePreferences.presetRelativePath),
      );
      if (presetFile.existsSync()) {
        return directory.path;
      }
      final parent = directory.parent;
      if (parent.path == directory.path) {
        return null;
      }
      directory = parent;
    }
  }

  String _presetForSourceRoot(String sourceRoot) {
    if (sourceRoot.isEmpty) {
      return '';
    }
    return p.join(sourceRoot, LocalRuntimePreferences.presetRelativePath);
  }

  Future<File> _preferencesFile(Object portableData) async {
    if (portableData is! PortableDataRoot) {
      throw ArgumentError.value(portableData, 'portableData');
    }
    final root = await portableData.clientDirectory();
    return File(p.join(root.path, _fileName));
  }
}
