import 'package:licoup/src/contracts/conversation_profile.dart';
import 'package:licoup/src/platform/storage/client_json_document_store.dart';

/// File-backed store for the conversation-profile registry
/// (`conversation-profiles.json`).
///
/// Mirrors the unread-cursor store idiom: one JSON document with a schema
/// version, atomic temp-file replace on save, and a tolerant load — a
/// missing document yields an empty registry. Malformed entries are
/// skipped so one bad record never blocks the whole list.
final class PlatformConversationProfileStore {
  const PlatformConversationProfileStore({
    ClientJsonDocumentStore jsonStore = const ClientJsonDocumentStore(),
  }) : _jsonStore = jsonStore;

  static const _fileName = 'conversation-profiles.json';

  final ClientJsonDocumentStore _jsonStore;

  Future<List<ConversationProfile>> load(Object portableData) async {
    final decoded = await _jsonStore.readCurrent(portableData, _fileName);
    if (decoded == null) {
      return const <ConversationProfile>[];
    }
    if (decoded is! Map || decoded['schemaVersion'] != 1) {
      throw StateError('conversation_profiles_requires_startup_migration');
    }
    final entries = decoded['profiles'];
    if (entries is! List) {
      return const <ConversationProfile>[];
    }
    return [
      for (final entry in entries)
        if (entry is Map)
          () {
            final profile = ConversationProfile.fromJson(
              Map<String, dynamic>.from(entry),
            );
            return profile.id.isNotEmpty && profile.agentId.isNotEmpty
                ? profile
                : null;
          }(),
    ].whereType<ConversationProfile>().toList(growable: false);
  }

  Future<void> save(
    Object portableData,
    List<ConversationProfile> profiles,
  ) async {
    await _jsonStore.write(portableData, _fileName, {
      'schemaVersion': 1,
      'profiles': [for (final profile in profiles) profile.toJson()],
    }, lock: true);
  }
}
