import '../support/client_controller_scenario_dependencies.dart';
import '../support/fake_agent_service.dart';

void registerClientSkillFreshnessScenarios() {
  test('skill hub refresh reuses a fresh catalog until forced', () async {
    final service = FakeAgentService();
    final controller = ClientController(agentService: service);
    addTearDown(controller.dispose);

    await controller.refreshSkillHub('codex');
    expect(controller.skillHubSkills, isNotEmpty);
    final pairingsAfterFirst = service.listPairingsCalls;
    final skillsAfterFirst = service.listSkillsCalls;

    await controller.refreshSkillHub('codex');
    expect(service.listPairingsCalls, pairingsAfterFirst);
    expect(service.listSkillsCalls, skillsAfterFirst);

    await controller.refreshSkillHub('codex', forceRefresh: true);
    expect(service.listPairingsCalls, greaterThan(pairingsAfterFirst));
    expect(service.listSkillsCalls, greaterThan(skillsAfterFirst));
  });
}
