import 'package:flutter_client/src/contracts/agent_orchestration_policy_merge.dart';
import 'package:flutter_client/src/contracts/agent_orchestration_policy_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('dispatch merge puts commander first and removes duplicate keys', () {
    const commander = AgentModelLibraryEntry(
      agentId: 'codex',
      modelName: 'gpt',
      reasoningEffort: 'high',
    );
    final result = agentOrchestrationDispatchModelLibrary(
      const AgentOrchestrationPolicy(
        commanderAgentId: 'codex',
        commanderModelName: 'gpt',
        commanderReasoningEffort: 'high',
        modelLibrary: [
          commander,
          AgentModelLibraryEntry(agentId: '', modelName: 'ignored'),
          AgentModelLibraryEntry(agentId: 'claude', modelName: 'opus'),
        ],
      ),
    );

    expect(result.map((entry) => entry.key), [
      commander.key,
      'claude\u001fopus\u001f',
    ]);
  });
}
