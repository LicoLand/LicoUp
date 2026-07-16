/// Native boundary for one-or-many-agent skill deletion.
abstract interface class SkillDeleteGateway {
  Future<Map<String, dynamic>> planSkillDelete({
    required List<String> agents,
    required String skillId,
    String installRoot = '',
  });

  Future<Map<String, dynamic>> applySkillDelete({
    required List<String> agents,
    required String skillId,
    required String confirmation,
    String installRoot = '',
  });
}

abstract interface class SkillDeleteViewModel {
  bool get isSkillDeleteBusy;

  Map<String, dynamic>? get skillDeletePlan;

  Future<void> previewSkillDelete({
    required Iterable<String> agents,
    required String skillId,
    String installRoot = '',
  });

  Future<void> applySkillDelete({
    required Iterable<String> agents,
    required String skillId,
    required String confirmation,
    String installRoot = '',
  });
}
