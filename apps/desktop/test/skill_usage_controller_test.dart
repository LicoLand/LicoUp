import 'package:licoup/src/application/features/skill_hub/controller/skill_usage_controller.dart';
import 'package:licoup/src/application/features/skill_hub/services/skill_usage_service.dart';
import 'package:licoup/src/contracts/skill_usage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('usage controller owns only the selected local window report', () async {
    final controller = SkillUsageController(
      service: SkillUsageService(gateway: _Gateway()),
      onStatus: (_) {},
    );
    addTearDown(controller.dispose);

    await controller.load(days: 7, agent: 'codex', skillId: 'review');
    expect(controller.report?['windowDays'], 7);
  });
}

class _Gateway implements SkillUsageGateway {
  @override
  Future<Map<String, dynamic>> reportSkillUsage({
    int days = 30,
    String agent = '',
    String skillId = '',
  }) async => {'ok': true, 'windowDays': days, 'totalInvocations': 4};
}
