import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'portable_data_root.dart';

class LocalRuntimePreferences {
  const LocalRuntimePreferences({this.port = defaultPort});

  static const currentSchemaVersion = 2;
  static const defaultPort = 17328;

  final int port;

  factory LocalRuntimePreferences.defaults() {
    return const LocalRuntimePreferences();
  }

  factory LocalRuntimePreferences.fromJson(Map<String, dynamic> json) {
    return LocalRuntimePreferences(port: _normalizePort(json['port']));
  }

  LocalRuntimePreferences copyWith({int? port}) {
    return LocalRuntimePreferences(port: port ?? this.port);
  }

  Map<String, dynamic> toJson() {
    return {'schemaVersion': currentSchemaVersion, 'port': port};
  }

  static int _normalizePort(Object? value) {
    final number = value is num
        ? value.toInt()
        : int.tryParse((value ?? '').toString());
    if (number == null || number <= 0 || number > 65535) {
      return defaultPort;
    }
    return number;
  }
}

class LocalRuntimePreferencesService {
  const LocalRuntimePreferencesService();

  static const _fileName = 'local-runtime-preferences.json';

  Future<LocalRuntimePreferences> load(PortableDataRoot portableData) async {
    final file = await _preferencesFile(portableData);
    if (await file.exists()) {
      try {
        final json = jsonDecode(await file.readAsString());
        if (json is Map<String, dynamic>) {
          return _normalize(LocalRuntimePreferences.fromJson(json));
        }
      } catch (_) {
        return _defaultPreferences();
      }
    }
    return _defaultPreferences();
  }

  Future<void> save(
    PortableDataRoot portableData,
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
    return LocalRuntimePreferences.defaults();
  }

  LocalRuntimePreferences _normalize(LocalRuntimePreferences preferences) {
    return LocalRuntimePreferences(port: preferences.port);
  }

  Future<File> _preferencesFile(PortableDataRoot portableData) async {
    final root = await portableData.futureClientDirectory();
    return File(p.join(root.path, _fileName));
  }
}
