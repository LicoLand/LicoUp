part of 'package:flutter_client/src/application/controller/client_controller.dart';

extension ClientSkillHubPreferencesActions on ClientController {
  Future<void> updateSkillVisualOverride({
    required String skillId,
    String? iconId,
    String? colorToken,
  }) async {
    final key = skillId.trim();
    if (key.isEmpty) return;

    final current = skillHubPreferences.overrideFor(key);
    final next = SkillVisualOverride(
      iconId: (iconId ?? current.iconId).trim(),
      colorToken: (colorToken ?? current.colorToken).trim(),
    );
    skillHubPreferences = skillHubPreferences.withOverride(key, next);
    _notifyStateChanged();
    await skillHubPreferencesService.save(portableData, skillHubPreferences);
  }
}
