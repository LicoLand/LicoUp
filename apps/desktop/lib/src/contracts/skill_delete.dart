/// Native boundary for moving one catalog skill directory to the system trash.
abstract interface class SkillDeleteGateway {
  Future<Map<String, dynamic>> planSkillDelete({
    required String skillId,
    required String path,
  });

  Future<Map<String, dynamic>> applySkillDelete({
    required String skillId,
    required String path,
    required String confirmation,
  });
}

abstract interface class SkillDeleteViewModel {
  bool get isSkillDeleteBusy;

  Map<String, dynamic>? get skillDeletePlan;

  Map<String, dynamic>? get skillDeleteResult;

  Future<void> previewSkillDelete({
    required String skillId,
    required String path,
  });

  Future<void> applySkillDelete({
    required String skillId,
    required String path,
    required String confirmation,
  });
}
