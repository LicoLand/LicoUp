import 'package:licoup/src/application/features/skill_hub/services/skill_usage_service.dart';
import 'package:licoup/src/contracts/skill_usage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('usage windows are selectable and bounded', () async {
    final gateway = _Gateway();
    final service = SkillUsageService(gateway: gateway);

    expect(() => service.report(days: 366), throwsA(isA<RangeError>()));
    await service.report(days: 90, agent: 'codex', skillId: 'review');
    expect(gateway.days, 90);
  });
}

class _Gateway implements SkillUsageGateway {
  int days = 0;

  @override
  Future<Map<String, dynamic>> reportSkillUsage({
    int days = 30,
    String agent = '',
    String skillId = '',
  }) async {
    this.days = days;
    return {'ok': true};
  }
}
