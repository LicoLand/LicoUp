import 'package:licoup/src/contracts/skill_hub_preferences.dart';
import 'package:licoup/src/platform/storage/client_json_document_store.dart';

class PlatformSkillHubPreferencesStore implements SkillHubPreferencesStore {
  const PlatformSkillHubPreferencesStore({
    ClientJsonDocumentStore jsonStore = const ClientJsonDocumentStore(),
  }) : _jsonStore = jsonStore;

  static const fileName = 'skill-hub-preferences.json';

  final ClientJsonDocumentStore _jsonStore;

  @override
  Future<Object?> read(Object portableData) {
    return _jsonStore.readCurrent(portableData, fileName);
  }

  @override
  Future<void> write(Object portableData, Object? payload) {
    return _jsonStore.write(portableData, fileName, payload);
  }
}
