import 'package:flutter_client/src/contracts/agent_orchestration_policy_models.dart';
import 'package:flutter_client/src/contracts/agent_orchestration_policy_validation.dart';
import 'package:flutter_client/src/contracts/target_candidate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('validation selects catalog defaults and rejects unknown entries', () {
    final target = _readyTarget();
    final normalized = normalizeAgentOrchestrationPolicy(
      [target],
      const AgentOrchestrationPolicy(
        id: ' ',
        commanderAgentId: ' codex ',
        commanderModelName: 'missing',
        commanderReasoningEffort: 'missing',
        modelLibrary: [
          AgentModelLibraryEntry(
            agentId: ' codex ',
            modelName: ' gpt ',
            reasoningEffort: ' high ',
          ),
          AgentModelLibraryEntry(agentId: 'other', modelName: 'unknown'),
        ],
      ),
    );

    expect(normalized.id, defaultAgentOrchestrationPolicyId);
    expect(normalized.commanderAgentId, 'codex');
    expect(normalized.commanderModelName, 'gpt');
    expect(normalized.commanderReasoningEffort, 'high');
    expect(normalized.modelLibrary, hasLength(1));
    expect(normalized.modelLibrary.single.key, 'codex\u001fgpt\u001fhigh');
  });
}

TargetCandidate _readyTarget() => TargetCandidate(
  target: 'codex',
  label: 'Codex',
  kind: 'cli',
  status: 'detected',
  configured: true,
  confidence: 1,
  adapterStatus: 'implemented',
  adapterCapabilities: const {
    'conversationDriver': 'implemented',
    'conversationReadiness': 'ready',
  },
  supportedActions: const ['runtime.message.send'],
  modelCatalog: const {
    'models': [
      {
        'name': 'gpt',
        'reasoningEfforts': ['high'],
      },
    ],
  },
);
