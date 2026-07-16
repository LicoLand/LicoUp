import 'package:flutter_client/src/application/features/skill_hub/services/skill_delete_service.dart';
import 'package:flutter_client/src/contracts/skill_delete.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('multi-agent deletion uses a stable unique target set', () async {
    final gateway = _Gateway();
    final service = SkillDeleteService(gateway: gateway);

    await service.plan(
      agents: const ['codex', 'claude-code', 'codex'],
      skillId: 'review',
    );

    expect(gateway.agents, ['claude-code', 'codex']);
  });
}

class _Gateway implements SkillDeleteGateway {
  List<String> agents = const [];

  @override
  Future<Map<String, dynamic>> planSkillDelete({
    required List<String> agents,
    required String skillId,
    String installRoot = '',
  }) async {
    this.agents = agents;
    return {'ok': true};
  }

  @override
  Future<Map<String, dynamic>> applySkillDelete({
    required List<String> agents,
    required String skillId,
    required String confirmation,
    String installRoot = '',
  }) async => {'ok': true};
}
