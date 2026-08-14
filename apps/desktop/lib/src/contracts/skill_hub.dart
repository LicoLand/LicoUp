import 'package:licoup/src/contracts/skill_hub_preferences.dart';

/// Narrow native boundary for pairing and read-only local catalog flows.
abstract interface class SkillHubGateway {
  Future<List<Map<String, dynamic>>> listPairings({String agent = ''});

  Future<Map<String, dynamic>> requestPairing({
    required String agent,
    String target = '',
  });

  Future<Map<String, dynamic>> approvePairing({required String agent});

  Future<Map<String, dynamic>> revokePairing({required String agent});

  Future<List<Map<String, dynamic>>> listSkills({required String agent});
}

abstract interface class SkillHubPreferencesRepository {
  Future<SkillHubPreferences> load(Object portableData);

  Future<void> save(Object portableData, SkillHubPreferences preferences);
}

abstract interface class SkillHubLocalCatalogSource {
  Future<List<Map<String, dynamic>>> scan({
    required Iterable<String> detectedAgentIds,
  });
}
