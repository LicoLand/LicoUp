import 'package:flutter_client/src/contracts/agent_orchestration_policy_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('policy and model entries expose only canonical value semantics', () {
    const entry = AgentModelLibraryEntry(
      agentId: ' codex ',
      modelName: ' gpt ',
      reasoningEffort: ' high ',
    );
    const policy = AgentOrchestrationPolicy(
      commanderAgentId: 'codex',
      commanderModelName: 'gpt',
      modelLibrary: [entry],
    );

    expect(policy.configured, isTrue);
    expect(entry.configured, isTrue);
    expect(entry.key, 'codex\u001fgpt\u001fhigh');
    expect(policy.copyWith(label: 'Default').label, 'Default');
  });
}
