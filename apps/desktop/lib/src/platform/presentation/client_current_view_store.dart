import 'package:licoup/src/contracts/presentation/client_current_view.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/platform/mobile_relay/mobile_relay_json_store.dart';

final class PlatformClientCurrentViewStore implements ClientCurrentViewStore {
  const PlatformClientCurrentViewStore({
    MobileRelayJsonStore jsonStore = const MobileRelayJsonStore(),
  }) : _jsonStore = jsonStore;

  static const _fileName = 'current-client-view.json';
  static const _schemaVersion = 1;
  static const _maxIdLength = 1024;

  final MobileRelayJsonStore _jsonStore;

  @override
  Future<ClientCurrentView?> load(Object portableData) async {
    final decoded = await _jsonStore.readCurrent(portableData, _fileName);
    if (decoded == null) return null;
    if (decoded is! Map || decoded['schemaVersion'] != _schemaVersion) {
      throw StateError('client_current_view_requires_startup_migration');
    }
    final section = _enumByName(ClientSection.values, decoded['section']);
    final conversationKind = _enumByName(
      ClientConversationViewKind.values,
      decoded['conversationKind'],
    );
    if (section == null || conversationKind == null) return null;
    try {
      return ClientCurrentView(
        section: section,
        conversationKind: conversationKind,
        groupConversationId: _normalizeId(decoded['groupConversationId']),
        agentId: _normalizeId(decoded['agentId']),
        sessionId: _normalizeId(decoded['sessionId']),
      );
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> save(Object portableData, ClientCurrentView view) =>
      _jsonStore.write(portableData, _fileName, {
        'schemaVersion': _schemaVersion,
        'section': view.section.name,
        'conversationKind': view.conversationKind.name,
        'groupConversationId': view.groupConversationId,
        'agentId': view.agentId,
        'sessionId': view.sessionId,
      }, lock: true);

  T? _enumByName<T extends Enum>(Iterable<T> values, Object? raw) {
    final name = raw?.toString().trim() ?? '';
    for (final value in values) {
      if (value.name == name) return value;
    }
    return null;
  }

  String _normalizeId(Object? value) {
    final id = value?.toString().trim() ?? '';
    return id.length <= _maxIdLength ? id : '';
  }
}
