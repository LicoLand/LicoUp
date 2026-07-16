import 'package:flutter_client/src/application/features/skill_hub/services/skill_update_service.dart';
import 'package:flutter_client/src/contracts/skill_update.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('update source selection is exclusive', () async {
    final gateway = _Gateway();
    final service = SkillUpdateService(gateway: gateway);

    expect(
      () => service.plan(
        agent: 'codex',
        skillId: 'review',
        githubUrl: 'https://github.com/example/review',
        mirrorPath: '/mirror/review',
      ),
      throwsArgumentError,
    );

    await service.plan(
      agent: 'codex',
      skillId: 'review',
      githubUrl: ' https://github.com/example/review ',
    );
    expect(gateway.url, 'https://github.com/example/review');
  });
}

class _Gateway implements SkillUpdateGateway {
  String url = '';

  @override
  Future<Map<String, dynamic>> planSkillUpdate({
    required String agent,
    required String skillId,
    String url = '',
    String sourcePath = '',
    String installRoot = '',
  }) async {
    this.url = url;
    return {'ok': true};
  }

  @override
  Future<Map<String, dynamic>> applySkillUpdate({
    required String agent,
    required String skillId,
    required String confirmation,
    String url = '',
    String sourcePath = '',
    String installRoot = '',
  }) async => {'ok': true};

  @override
  Future<Map<String, dynamic>> configureSkillAutoUpdate({
    required String agent,
    required String skillId,
    required bool enabled,
    String url = '',
    String sourcePath = '',
  }) async => {'ok': true};

  @override
  Future<Map<String, dynamic>> runConfiguredSkillUpdates({
    required String agent,
    String skillId = '',
  }) async => {'ok': true};

  @override
  Future<Map<String, dynamic>> runDueSkillUpdates() async => {'ok': true};
}
