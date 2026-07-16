import 'package:flutter_client/src/contracts/skill_usage.dart';

final class SkillUsageService {
  const SkillUsageService({required SkillUsageGateway gateway})
    : _gateway = gateway;

  final SkillUsageGateway _gateway;

  Future<Map<String, dynamic>> report({
    int days = 30,
    String agent = '',
    String skillId = '',
  }) {
    if (days < 1 || days > 365) {
      throw RangeError.range(days, 1, 365, 'days');
    }
    return _gateway.reportSkillUsage(
      days: days,
      agent: agent.trim(),
      skillId: skillId.trim(),
    );
  }
}
