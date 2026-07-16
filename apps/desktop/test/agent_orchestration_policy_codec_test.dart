import 'package:flutter_client/src/contracts/agent_orchestration_policy_codec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('codec accepts legacy commander fields and emits canonical schema', () {
    final policy = AgentOrchestrationPolicyCodec.decode({
      'commanderAgentId': ' codex ',
      'commanderModelName': ' gpt ',
      'commanderReasoningEffort': ' high ',
      'modelLibrary': [
        {'agentId': 'claude', 'modelName': 'opus'},
      ],
    });

    expect(policy.id, 'default');
    expect(policy.commanderAgentId, 'codex');
    expect(policy.commanderModelName, 'gpt');
    final encoded = AgentOrchestrationPolicyCodec.encode(policy);
    expect(encoded['schemaVersion'], 1);
    expect(encoded['commander'], {
      'agentId': 'codex',
      'modelName': 'gpt',
      'reasoningEffort': 'high',
    });
    expect(encoded, isNot(contains('commanderAgentId')));
  });
}
