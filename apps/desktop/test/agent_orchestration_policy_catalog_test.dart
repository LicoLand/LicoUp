import 'package:flutter_client/src/contracts/agent_orchestration_policy_catalog.dart';
import 'package:flutter_client/src/contracts/agent_orchestration_policy_models.dart';
import 'package:flutter_client/src/contracts/target_candidate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('catalog projection never invents fallback models', () {
    final missingCatalogTarget = _target('antigravity');
    expect(agentOrchestrationCommanderModels(missingCatalogTarget), isEmpty);
    expect(
      agentOrchestrationModelLibraryCandidates([missingCatalogTarget]),
      isEmpty,
    );
  });

  test('catalog projects display names and model-scoped reasoning', () {
    final codex = _target(
      'codex',
      modelCatalog: const {
        'models': [
          {
            'name': 'gpt-5.5',
            'displayName': 'GPT-5.5',
            'reasoningEfforts': ['high'],
          },
        ],
      },
    );
    expect(agentOrchestrationCommanderModels(codex), ['gpt-5.5']);
    expect(agentOrchestrationModelDisplayName(codex, 'gpt-5.5'), 'GPT-5.5');
    expect(agentOrchestrationReasoningEffortsForModel(codex, 'gpt-5.5'), [
      'high',
    ]);
    expect(agentOrchestrationModelLibraryCandidates([codex]), [
      isA<AgentModelLibraryEntry>()
          .having((entry) => entry.agentId, 'agent', 'codex')
          .having((entry) => entry.modelName, 'model', 'gpt-5.5')
          .having((entry) => entry.reasoningEffort, 'effort', 'high'),
    ]);
  });
}

TargetCandidate _target(
  String id, {
  Map<String, dynamic> modelCatalog = const {},
}) => TargetCandidate(
  target: id,
  label: id,
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
  modelCatalog: modelCatalog,
);
