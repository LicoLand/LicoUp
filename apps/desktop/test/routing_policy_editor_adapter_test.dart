import 'package:flutter_client/src/application/features/routing/controller/routing_policy_editor_adapter.dart';
import 'package:flutter_client/src/contracts/agent_orchestration_policy.dart';
import 'package:flutter_client/src/contracts/routing/routing_policy_schema.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('editor save preserves the complete canonical routing policy', () {
    const base = RoutingPolicyDocument(
      id: 'policy',
      label: 'Original',
      agents: [
        RoutingPolicyAgent(
          id: 'codex',
          modelName: 'old-model',
          reasoningEffort: 'medium',
          roles: ['implementation'],
          capabilities: ['tool-use'],
          priority: 5,
          distillation: RoutingAgentDistillation(
            distiller: 'self',
            maxLength: 2048,
            preserveFields: ['objective', 'constraints'],
          ),
        ),
      ],
      routing: RoutingPolicyRouting(
        circuitBreaker: RoutingCircuitBreakerConfig(
          allowedFails: 2,
          cooldownSeconds: 120,
        ),
        switchPolicy: RoutingSwitchPolicy(minimumIntervalSeconds: 45),
      ),
      distillation: RoutingPolicyDistillation(
        defaultDistiller: 'codex',
        alternateDistiller: 'fallback',
        fidelityContract: RoutingFidelityContract(
          requiredSections: ['objective', 'constraints'],
          maxPackageLength: 4096,
          maxRetries: 2,
        ),
      ),
    );
    const editor = AgentOrchestrationPolicy(
      id: 'policy',
      label: 'Edited',
      commanderAgentId: 'codex',
      commanderModelName: 'new-model',
      commanderReasoningEffort: 'high',
    );

    final saved = routingPolicyFromEditor(editor, basePolicy: base);

    expect(saved.label, 'Edited');
    expect(saved.agents.single.modelName, 'new-model');
    expect(saved.agents.single.reasoningEffort, 'high');
    expect(saved.agents.single.roles, ['implementation']);
    expect(saved.agents.single.capabilities, ['tool-use']);
    expect(saved.agents.single.distillation.maxLength, 2048);
    expect(saved.routing.circuitBreaker.allowedFails, 2);
    expect(saved.routing.switchPolicy.minimumIntervalSeconds, 45);
    expect(saved.distillation.defaultDistiller, 'codex');
    expect(saved.distillation.fidelityContract.maxRetries, 2);
  });
}
