import 'package:licoup/src/contracts/agent_orchestration_target.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'virtual orchestration target is local and never aliases real agents',
    () {
      final target = agentOrchestrationTargetCandidate(label: 'Default');

      expect(
        isAgentOrchestrationTargetId(' $agentOrchestrationTargetId '),
        isTrue,
      );
      expect(isAgentOrchestrationTargetId('codex'), isFalse);
      expect(target.target, agentOrchestrationTargetId);
      expect(target.kind, 'multi-agent-orchestration');
      expect(target.scanSource, 'local-ui');
      expect(target.adapterCapabilities['virtual'], isTrue);
    },
  );
}
