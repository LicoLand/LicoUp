import 'package:licoup/src/application/features/skill_hub/controller/skill_delete_controller.dart';
import 'package:licoup/src/application/features/skill_hub/services/skill_delete_service.dart';
import 'package:licoup/src/contracts/skill_delete.dart';
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
        skillId: 'review',
        path: '/workspace/.agents/skills/review',
      );
      await controller.apply(
        skillId: 'review',
        path: '/workspace/.agents/skills/review',
        confirmation: controller.plan!['confirmation'].toString(),
      );
      expect(gateway.confirmation, 'trash:review:plan-digest');
      expect(controller.actionResult?['status'], 'trashed');
    },
  );
}

class _Gateway implements SkillDeleteGateway {
  String confirmation = '';

  @override
  Future<Map<String, dynamic>> planSkillDelete({
    required String skillId,
    required String path,
  }) async => {'ok': true, 'confirmation': 'trash:$skillId:plan-digest'};

  @override
  Future<Map<String, dynamic>> applySkillDelete({
    required String skillId,
    required String path,
    required String confirmation,
  }) async {
    this.confirmation = confirmation;
    return {'ok': true, 'status': 'trashed'};
  }
}
