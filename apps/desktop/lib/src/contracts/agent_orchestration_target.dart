import 'package:licoup/src/contracts/target_candidate.dart';

const String agentOrchestrationTargetId = 'lico-default-orchestrator';

bool isAgentOrchestrationTargetId(String targetId) =>
    targetId.trim() == agentOrchestrationTargetId;

TargetCandidate agentOrchestrationTargetCandidate({String label = 'Lico'}) {
  return TargetCandidate(
    target: agentOrchestrationTargetId,
    label: label,
    kind: 'multi-agent-orchestration',
    status: 'detected',
    configured: true,
    confidence: 1,
    adapterStatus: 'local-strategy',
    adapterCapabilities: const {'virtual': true},
    supportedActions: const ['runtime.message.send'],
    scanSource: 'local-ui',
  );
}
