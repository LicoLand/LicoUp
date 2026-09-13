import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/adaptive_flywheel_renderer_models.dart';

void main() {
  test('picker shows only the model name and keeps planning facts private', () {
    final target = TargetCandidate(
      target: 'kimi-code',
      label: 'kimi-code',
      kind: 'cli',
      status: 'detected',
      configured: true,
      confidence: 1,
      binaryPath: '/synthetic/bin/kimi-code',
      adapterStatus: 'implemented',
      adapterCapabilities: const {'conversationDriver': 'implemented'},
      modelCatalog: const {
        'models': [
          {
            'name': 'kimi-k3',
            'displayName': 'Kimi K3',
            'codingScore': 61,
            'taskTags': ['frontend', 'backend'],
          },
        ],
      },
    );
    expect(agentOrchestrationModelPickerLabel(target, 'kimi-k3'), 'Kimi K3');
  });
}
