import '../support/client_controller_scenario_dependencies.dart';
import '../support/fake_agent_service.dart';

void registerClientSkillManagementScenarios() {
  test('supports skill hub state machine and busy lock', () async {
    final service = FakeAgentService();
    final controller = ClientController(agentService: service);
    addTearDown(controller.dispose);

    await controller.requestSkillHubPairing('codex', target: 'manual');
    await controller.approveSkillHubPairing('codex');
    await controller.refreshSkillHub('codex');

    expect(controller.skillHubPairings, hasLength(1));
    expect(controller.skillHubSkills, hasLength(1));
    expect(controller.skillHubActionResult?['agent'], 'codex');

    await controller.revokeSkillHubPairing('codex');
    expect(controller.skillHubSkills, isEmpty);

    service.skillBusyGate = Completer<void>();
    unawaited(controller.refreshSkillHub('codex'));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await controller.refreshSkillHub('codex');
    expect(service.listPairingsCalls, greaterThanOrEqualTo(5));
    expect(service.listSkillsCalls, greaterThanOrEqualTo(3));
    service.skillBusyGate!.complete();
    await Future<void>.delayed(Duration.zero);
  });

  test('reports skill hub action failures', () async {
    final service = FakeAgentService()..throwListPairings = true;
    final controller = ClientController(agentService: service);
    addTearDown(controller.dispose);

    await controller.refreshSkillHub('codex');

    expect(controller.lastError, 'skill_hub_operation_failed');
    expect(controller.statusMessage, '技能中心操作失败。');
    controller.localePreference = 'en';
    expect(controller.displayStatusMessage, 'The Skill Hub operation failed.');
    expect(controller.isSkillHubBusy, isFalse);
  });

  test('supports GitHub skill install preview apply and rollback', () async {
    final service = FakeAgentService()..skills = const [];
    final controller = ClientController(agentService: service);
    addTearDown(controller.dispose);

    await controller.previewSkillInstall(
      agent: 'codex',
      url: 'https://github.com/example/skills/tree/main/review-helper',
      installRoot: '/tmp/codex-skills',
      name: 'review-helper',
      overwrite: true,
    );

    expect(service.planSkillInstallCalls, 1);
    expect(service.installedSkillAgent, 'codex');
    expect(service.installedSkillUrl, contains('github.com/example/skills'));
    expect(service.installedSkillRoot, '/tmp/codex-skills');
    expect(service.installedSkillName, 'review-helper');
    expect(service.installedSkillOverwrite, isTrue);
    expect(controller.skillInstallPlan?['status'], 'planned');

    await controller.installSkillFromGitHub(
      agent: 'codex',
      url: 'https://github.com/example/skills/tree/main/review-helper',
      installRoot: '/tmp/codex-skills',
      name: 'review-helper',
      overwrite: true,
      pin: true,
    );

    expect(service.applySkillInstallCalls, 1);
    expect(service.installedSkillPin, isTrue);
    expect(controller.skillInstallResult?['status'], 'installed');
    expect(controller.skillHubSkills.single['skillId'], 'review-helper');

    await controller.rollbackSkillInstall(
      agent: 'codex',
      snapshotId: 'skill-install-snapshot-1',
    );

    expect(service.rollbackSkillInstallCalls, 1);
    expect(
      service.rolledBackSkillInstallSnapshotId,
      'skill-install-snapshot-1',
    );
    expect(controller.skillInstallResult?['status'], 'rolled_back');
    expect(controller.skillHubSkills, isEmpty);
  });
}
