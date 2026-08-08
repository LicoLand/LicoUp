import 'package:licoup/src/application/features/skill_hub/controller/skill_update_controller.dart';
import 'package:licoup/src/application/features/skill_hub/services/skill_update_service.dart';
import 'package:licoup/src/contracts/skill_update.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('manual update forwards only the reviewed confirmation', () async {
    final gateway = _Gateway();
    final controller = SkillUpdateController(
      service: SkillUpdateService(gateway: gateway),
      onStatus: (_) {},
    );
    addTearDown(controller.dispose);

    await controller.preview(agent: 'codex', skillId: 'review');
    await controller.apply(
      agent: 'codex',
      skillId: 'review',
      confirmation: controller.plan!['confirmation'].toString(),
    );
    expect(gateway.confirmation, 'update:review:codex:digest');
  });

  test(
    'configured update is enabled only by an explicit controller action',
    () async {
      final gateway = _Gateway();
      final controller = SkillUpdateController(
        service: SkillUpdateService(gateway: gateway),
        onStatus: (_) {},
      );
      addTearDown(controller.dispose);

      expect(gateway.configureCalls, 0);
      await controller.configure(
        agent: 'codex',
        skillId: 'review',
        enabled: true,
        mirrorPath: '/mirror/review',
      );
      await controller.runConfigured(agent: 'codex', skillId: 'review');
      expect(gateway.configureCalls, 1);
      expect(gateway.runCalls, 1);
    },
  );
}

class _Gateway implements SkillUpdateGateway {
  String confirmation = '';
  int configureCalls = 0;
  int runCalls = 0;

  @override
  Future<Map<String, dynamic>> planSkillUpdate({
    required String agent,
    required String skillId,
    String url = '',
    String sourcePath = '',
    String installRoot = '',
  }) async => {'ok': true, 'confirmation': 'update:$skillId:$agent:digest'};

  @override
  Future<Map<String, dynamic>> applySkillUpdate({
    required String agent,
    required String skillId,
    required String confirmation,
    String url = '',
    String sourcePath = '',
    String installRoot = '',
  }) async {
    this.confirmation = confirmation;
    return {'ok': true};
  }

  @override
  Future<Map<String, dynamic>> configureSkillAutoUpdate({
    required String agent,
    required String skillId,
    required bool enabled,
    String url = '',
    String sourcePath = '',
  }) async {
    configureCalls += 1;
    return {'ok': true};
  }

  @override
  Future<Map<String, dynamic>> runConfiguredSkillUpdates({
    required String agent,
    String skillId = '',
  }) async {
    runCalls += 1;
    return {'ok': true};
  }

  @override
  Future<Map<String, dynamic>> runDueSkillUpdates() async => {'ok': true};
}
