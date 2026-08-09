import 'package:licoup/src/contracts/agent_last_used_conversation.dart';
import 'package:licoup/src/platform/mobile_relay/mobile_relay_json_store.dart';

/// JSON-file persistence for the last-used conversation reference, stored
/// under the portable data root next to the other client-owned stores.
final class PlatformLastUsedConversationStore
    implements LastUsedConversationStore {
  const PlatformLastUsedConversationStore({
    MobileRelayJsonStore jsonStore = const MobileRelayJsonStore(),
  }) : _jsonStore = jsonStore;

  static const _fileName = 'last-used-conversation.json';
  static const _schemaVersion = 1;
  static const _maxIdLength = 1024;

  final MobileRelayJsonStore _jsonStore;

  @override
  Future<LastUsedConversationRef?> load(Object portableData) async {
    final decoded = await _jsonStore.read(portableData, _fileName);
    if (decoded is! Map || decoded['schemaVersion'] != _schemaVersion) {
      return null;
    }
    final agentId = _normalizeId(decoded['agentId']);
    if (agentId.isEmpty) {
      return null;
    }
    return LastUsedConversationRef(
      agentId: agentId,
      sessionId: _normalizeId(decoded['sessionId']),
    );
  }

  @override
  Future<void> save(Object portableData, LastUsedConversationRef ref) async {
    if (ref.isEmpty) {
      return;
    }
    await _jsonStore.write(portableData, _fileName, {
      'schemaVersion': _schemaVersion,
      'agentId': _normalizeId(ref.agentId),
      'sessionId': _normalizeId(ref.sessionId),
    }, lock: true);
  }

  String _normalizeId(Object? value) {
    final id = value?.toString().trim() ?? '';
    return id.length <= _maxIdLength ? id : '';
  }
}
