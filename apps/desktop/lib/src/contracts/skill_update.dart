/// Native boundary for manual and configured skill updates.
abstract interface class SkillUpdateGateway {
  Future<Map<String, dynamic>> planSkillUpdate({
    required String agent,
    required String skillId,
    String url = '',
    String sourcePath = '',
    String installRoot = '',
  });

  Future<Map<String, dynamic>> applySkillUpdate({
    required String agent,
    required String skillId,
    required String confirmation,
    String url = '',
    String sourcePath = '',
    String installRoot = '',
  });

  Future<Map<String, dynamic>> configureSkillAutoUpdate({
    required String agent,
    required String skillId,
    required bool enabled,
    String url = '',
    String sourcePath = '',
  });

  Future<Map<String, dynamic>> runConfiguredSkillUpdates({
    required String agent,
    String skillId = '',
  });

  /// Runs only policies that were explicitly enabled and are currently due.
  Future<Map<String, dynamic>> runDueSkillUpdates();
}

abstract interface class SkillUpdateViewModel {
  bool get isSkillUpdateBusy;

  Map<String, dynamic>? get skillUpdatePlan;

  Future<void> previewSkillUpdate({
    required String agent,
    required String skillId,
    String githubUrl = '',
    String mirrorPath = '',
    String installRoot = '',
  });

  Future<void> applySkillUpdate({
    required String agent,
    required String skillId,
    required String confirmation,
    String githubUrl = '',
    String mirrorPath = '',
    String installRoot = '',
  });

  Future<void> configureSkillAutoUpdate({
    required String agent,
    required String skillId,
    required bool enabled,
    String githubUrl = '',
    String mirrorPath = '',
  });

  Future<void> runConfiguredSkillUpdates({
    required String agent,
    String skillId = '',
  });
}
