import 'package:flutter_client/src/contracts/skill_hub_preferences.dart';
import 'package:flutter_client/src/contracts/skill_hub.dart';

class SkillHubPreferencesService implements SkillHubPreferencesRepository {
  const SkillHubPreferencesService({required SkillHubPreferencesStore store})
    : _store = store;

  final SkillHubPreferencesStore _store;

  @override
  Future<SkillHubPreferences> load(Object portableData) async {
    try {
      final json = await _store.read(portableData);
      if (json is! Map) {
        return SkillHubPreferences.defaults();
      }
      return SkillHubPreferences.fromJson(Map<String, dynamic>.from(json));
    } catch (_) {
      return SkillHubPreferences.defaults();
    }
  }

  @override
  Future<void> save(Object portableData, SkillHubPreferences preferences) {
    return _store.write(portableData, preferences.toJson());
  }
}
