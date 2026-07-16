/// Native boundary for aggregate-only local skill usage reports.
abstract interface class SkillUsageGateway {
  Future<Map<String, dynamic>> reportSkillUsage({
    int days = 30,
    String agent = '',
    String skillId = '',
  });
}

abstract interface class SkillUsageViewModel {
  bool get isSkillUsageBusy;

  Map<String, dynamic>? get skillUsageReport;

  Future<void> loadSkillUsage({
    int days = 30,
    String agent = '',
    String skillId = '',
  });
}
