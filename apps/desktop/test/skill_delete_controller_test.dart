import 'package:flutter_client/src/application/features/skill_hub/controller/skill_delete_controller.dart';
import 'package:flutter_client/src/application/features/skill_hub/services/skill_delete_service.dart';
import 'package:flutter_client/src/contracts/skill_delete.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'delete controller keeps plan and apply independently testable',
    () async {
      final gateway = _Gateway();
      final controller = SkillDeleteController(
        service: SkillDeleteService(gateway: gateway),
        onStatus: (_) {},
      );
      addTearDown(controller.dispose);

      await controller.preview(
        agents: const ['codex', 'claude-code'],
        skillId: 'review',
      );
      await controller.apply(
        agents: const ['codex', 'claude-code'],
        skillId: 'review',
        confirmation: controller.plan!['confirmation'].toString(),
      );
      expect(gateway.confirmation, 'delete:review:claude-code,codex');
    },
  );
}

class _Gateway implements SkillDeleteGateway {
  String confirmation = '';

  @override
  Future<Map<String, dynamic>> planSkillDelete({
    required List<String> agents,
    required String skillId,
    String installRoot = '',
  }) async => {
    'ok': true,
    'confirmation': 'delete:$skillId:${([...agents]..sort()).join(',')}',
  };

  @override
  Future<Map<String, dynamic>> applySkillDelete({
    required List<String> agents,
    required String skillId,
    required String confirmation,
    String installRoot = '',
  }) async {
    this.confirmation = confirmation;
    return {'ok': true};
  }
}
