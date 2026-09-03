import 'package:licoup/src/contracts/skill_hub_preferences.dart';
import 'package:licoup/src/platform/mobile_relay/mobile_relay_json_store.dart';

class PlatformSkillHubPreferencesStore implements SkillHubPreferencesStore {
  const PlatformSkillHubPreferencesStore({
    MobileRelayJsonStore jsonStore = const MobileRelayJsonStore(),
  }) : _jsonStore = jsonStore;

  static const fileName = 'skill-hub-preferences.json';

  final MobileRelayJsonStore _jsonStore;

  @override
  Future<Object?> read(Object portableData) {
    return _jsonStore.readCurrent(portableData, fileName);
  }

  @override
  Future<void> write(Object portableData, Object? payload) {
    return _jsonStore.write(portableData, fileName, payload);
  }
}
