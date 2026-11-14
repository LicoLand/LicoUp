import 'package:licoup/src/platform/storage/client_json_document_store.dart';

/// File-backed store for the self-mascot identity
/// (`self-mascot-identity.json`).
///
/// Mirrors the unread-cursor store idiom: one JSON document with a schema
/// version, atomic temp-file replace on save, and a tolerant load — a missing
/// document yields null so the caller can initialize the first-run random
/// pick and persist it once. The composition root adapts this onto the
/// renderer-facing `SelfMascotStore` port.
final class PlatformSelfMascotIdentityStore {
  const PlatformSelfMascotIdentityStore({
    ClientJsonDocumentStore jsonStore = const ClientJsonDocumentStore(),
  }) : _jsonStore = jsonStore;

  static const _fileName = 'self-mascot-identity.json';

  final ClientJsonDocumentStore _jsonStore;

  Future<String?> load(Object portableData) async {
    final decoded = await _jsonStore.readCurrent(portableData, _fileName);
    if (decoded == null) {
      return null;
    }
    if (decoded is! Map || decoded['schemaVersion'] != 1) {
      throw StateError('self_mascot_identity_requires_startup_migration');
    }
    final id = decoded['mascotId'];
    if (id is! String || id.trim().isEmpty) {
      return null;
    }
    return id.trim();
  }

  /// Persists [mascotId] and returns the normalized id actually written, so
  /// the wiring layer can refresh the renderer's last-known seed.
  Future<String> save(Object portableData, String mascotId) async {
    final resolved = mascotId.trim();
    await _jsonStore.write(portableData, _fileName, {
      'schemaVersion': 1,
      'mascotId': resolved,
    }, lock: true);
    return resolved;
  }
}
