import 'package:licoup/src/application/features/skill_hub/services/skill_delete_service.dart';
import 'package:licoup/src/contracts/skill_delete.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('skill trash plan normalizes required identifiers and paths', () async {
    final gateway = _Gateway();
    final service = SkillDeleteService(gateway: gateway);

    await service.plan(
      skillId: ' review ',
      path: ' /workspace/.agents/skills/review ',
    );

    expect(gateway.skillId, 'review');
    expect(gateway.path, '/workspace/.agents/skills/review');
  });
}

class _Gateway implements SkillDeleteGateway {
  String skillId = '';
  String path = '';

  @override
  Future<Map<String, dynamic>> planSkillDelete({
    required String skillId,
    required String path,
  }) async {
    this.skillId = skillId;
    this.path = path;
    return {'ok': true};
  }

  @override
  Future<Map<String, dynamic>> applySkillDelete({
    required String skillId,
    required String path,
    required String confirmation,
  }) async => {'ok': true};
}
