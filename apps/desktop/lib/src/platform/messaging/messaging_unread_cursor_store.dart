import 'package:licoup/src/platform/storage/client_json_document_store.dart';

/// The decoded cursor document before the renderer-facing snapshot type is
/// attached by the composition adapter.
typedef PlatformUnreadCursorDocument = ({
  Map<String, int> cursors,
  int baselineAtUnixMs,
});

/// File-backed store for conversation read cursors
/// (`messaging-unread-cursors.json`).
///
/// Mirrors the feature-order store idiom: one JSON document with a schema
/// version, atomic temp-file replace on save, and a tolerant load — a missing
/// document yields null so the caller can seed first-run cursors. The
/// composition root adapts this onto the renderer-facing
/// `MessagingUnreadCursorStore` port.
///
/// Schema 2 adds `baselineAtUnixMs`: the instant the document started
/// accounting for conversations. Schema-1 documents predate per-session
/// coverage, so their baseline is the file's own modification time — every
/// conversation idle since then is provably pre-existing history. A save
/// always carries the baseline of the document it replaces forward so a
/// rewrite never silently widens coverage over genuinely new sessions.
final class PlatformMessagingUnreadCursorStore {
  const PlatformMessagingUnreadCursorStore({
    ClientJsonDocumentStore jsonStore = const ClientJsonDocumentStore(),
  }) : _jsonStore = jsonStore;

  static const _fileName = 'messaging-unread-cursors.json';
  static const _schemaVersion = 2;

  final ClientJsonDocumentStore _jsonStore;

  Future<PlatformUnreadCursorDocument?> load(Object portableData) async {
    final decoded = await _readDocument(portableData);
    if (decoded == null) {
      return null;
    }
    final cursors = _parseCursors(decoded.document['cursors']);
    if (cursors == null) {
      return null;
    }
    final baseline = decoded.version == _schemaVersion
        ? _integer(decoded.document['baselineAtUnixMs'])
        : 0;
    return (
      cursors: cursors,
      baselineAtUnixMs: baseline > 0
          ? baseline
          : await _baselineFallback(portableData),
    );
  }

  /// Persists [cursors] and returns the normalized map actually written, so
  /// the wiring layer can refresh the renderer's last-known seed. The
  /// baseline of the replaced document is carried forward.
  Future<Map<String, int>> save(
    Object portableData,
    Map<String, int> cursors,
  ) async {
    final resolved = <String, int>{
      for (final entry in cursors.entries)
        if (entry.key.trim().isNotEmpty && entry.value > 0)
          entry.key.trim(): entry.value,
    };
    final baseline = await _baselineForSave(portableData);
    await _jsonStore.write(portableData, _fileName, {
      'schemaVersion': _schemaVersion,
      'baselineAtUnixMs': baseline,
      'cursors': resolved,
    }, lock: true);
    return Map.unmodifiable(resolved);
  }

  Future<int> _baselineForSave(Object portableData) async {
    final decoded = await _readDocument(portableData);
    if (decoded != null && decoded.version == _schemaVersion) {
      final baseline = _integer(decoded.document['baselineAtUnixMs']);
      if (baseline > 0) {
        return baseline;
      }
    }
    return _baselineFallback(portableData);
  }

  /// Baseline for documents that do not carry one: the file's own
  /// modification time marks the end of its coverage; a missing stat falls
  /// back to now so history is adopted rather than flagged.
  Future<int> _baselineFallback(Object portableData) async {
    final modified = await _jsonStore.modifiedAt(portableData, _fileName);
    return (modified ?? DateTime.now()).millisecondsSinceEpoch;
  }

  Map<String, int>? _parseCursors(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final cursors = <String, int>{};
    for (final entry in raw.entries) {
      final id = entry.key.toString().trim();
      final value = entry.value;
      if (id.isEmpty || value is! int || value < 0) {
        continue;
      }
      cursors[id] = value;
    }
    return Map.unmodifiable(cursors);
  }

  int _integer(Object? raw) => raw is int ? raw : 0;

  Future<({Map<String, dynamic> document, int version})?> _readDocument(
    Object portableData,
  ) async {
    final decoded = await _jsonStore.readCurrent(portableData, _fileName);
    if (decoded == null) {
      return null;
    }
    if (decoded is! Map) {
      throw StateError('messaging_unread_cursors_requires_startup_migration');
    }
    final document = Map<String, dynamic>.from(decoded);
    final version = _integer(document['schemaVersion']);
    if (version != 1 && version != _schemaVersion) {
      throw StateError('messaging_unread_cursors_requires_startup_migration');
    }
    return (document: document, version: version);
  }
}
