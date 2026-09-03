import 'package:licoup/src/contracts/skill_hub_preferences.dart';
import 'package:licoup/src/contracts/skill_hub.dart';

class SkillHubPreferencesService implements SkillHubPreferencesRepository {
  const SkillHubPreferencesService({required SkillHubPreferencesStore store})
    : _store = store;

  final SkillHubPreferencesStore _store;

  @override
  Future<SkillHubPreferences> load(Object portableData) async {
    final json = await _store.read(portableData);
    if (json == null) {
      return SkillHubPreferences.defaults();
    }
    if (json is! Map) {
      throw const FormatException('skill_hub_preferences_invalid');
    }
    return SkillHubPreferences.fromJson(Map<String, dynamic>.from(json));
  }

  @override
  Future<void> save(Object portableData, SkillHubPreferences preferences) {
    return _store.write(portableData, preferences.toJson());
  }
}
