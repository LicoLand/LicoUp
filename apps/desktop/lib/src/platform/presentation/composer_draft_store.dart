import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:licoup/src/contracts/presentation/composer_drafts.dart';
import 'package:licoup/src/platform/storage/client_json_document_store.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';

/// Client-state document holding the unsent composer text of each conversation
/// scope.
///
/// The document lives beside the other presentation documents under
/// `<data root>/client-state/`, is written atomically under a file lock, and
/// carries its own current schema version. A draft is optional state, so the
/// store never turns an unreadable document into a fresh one: [load] answers
/// `null` instead, and its caller keeps drafts in memory while the existing
/// bytes stay untouched.
final class PlatformComposerDraftStore implements ComposerDraftStore {
  const PlatformComposerDraftStore({
    ClientJsonDocumentStore jsonStore = const ClientJsonDocumentStore(),
  }) : _jsonStore = jsonStore;

  static const _fileName = 'composer-drafts.json';
  static const _schemaVersion = 1;
  static const _maxDocumentBytes = 4 * 1024 * 1024;
  static const _maxScopeLength = 1024;

  final ClientJsonDocumentStore _jsonStore;

  @override
  Future<Map<String, String>?> load(Object portableData) async {
    if (portableData is! PortableDataRoot) {
      throw ArgumentError.value(portableData, 'portableData');
    }
    final file = await _documentFile(portableData);
    if (!await file.exists()) return const {};
    if (await file.length() > _maxDocumentBytes) return null;
    final Object? decoded;
    try {
      decoded = await _jsonStore.readCurrent(portableData, _fileName);
    } on FormatException {
      // Unreadable bytes are preserved, not replaced.
      return null;
    }
    if (decoded == null) return const {};
    if (decoded is! Map || decoded['schemaVersion'] != _schemaVersion) {
      return null;
    }
    final raw = decoded['drafts'];
    if (raw is! Map) return null;
    final drafts = <String, String>{};
    for (final entry in raw.entries) {
      final scope = entry.key;
      final value = entry.value;
      if (scope is! String || value is! String) return null;
      final normalized = scope.trim();
      if (normalized.isEmpty || normalized.length > _maxScopeLength) {
        return null;
      }
      if (value.isEmpty) continue;
      drafts[normalized] = value;
    }
    return Map<String, String>.unmodifiable(drafts);
  }

  @override
  Future<void> save(Object portableData, Map<String, String> drafts) {
    final ordered = <String, String>{};
    for (final scope in drafts.keys.toList()..sort()) {
      final value = drafts[scope] ?? '';
      if (value.isEmpty) continue;
      ordered[scope] = value;
    }
    return _jsonStore.write(portableData, _fileName, {
      'schemaVersion': _schemaVersion,
      'drafts': ordered,
    }, lock: true);
  }

  Future<File> _documentFile(PortableDataRoot portableData) async {
    final directory = await portableData.clientDirectory();
    return File(p.join(directory.path, _fileName));
  }
}
