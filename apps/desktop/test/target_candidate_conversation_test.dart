import 'package:flutter_client/src/contracts/target_candidate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'only local concrete candidates enter the native conversation surface',
    () {
      final local = TargetCandidate(
        target: 'codex',
        label: 'Codex',
        kind: 'cli',
        status: 'detected',
        configured: true,
        confidence: 1,
        adapterStatus: 'implemented',
      );
      final remote = TargetCandidate(
        target: 'codex',
        label: 'Remote Codex',
        kind: 'cli',
        status: 'detected',
        configured: true,
        confidence: 1,
        adapterStatus: 'implemented',
        location: 'docker',
      );

      expect(local.isConversationAgent, isTrue);
      expect(remote.isConversationAgent, isFalse);
    },
  );
}
