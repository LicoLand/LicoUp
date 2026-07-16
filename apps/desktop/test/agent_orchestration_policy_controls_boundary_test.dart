import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('orchestration policy surface delegates independent dialog cards', () {
    final root = File(
      'lib/src/frontend/features/agents/ui/agent_orchestration_policy_controls.dart',
    ).readAsStringSync();
    final dialog = File(
      'lib/src/frontend/features/agents/ui/agent_orchestration_policy_dialog.dart',
    ).readAsStringSync();

    expect(root.split('\n'), hasLength(lessThan(120)));
    expect(root, isNot(contains('class _ModelLibrary')));
    expect(dialog, contains('AgentOrchestrationCommanderPolicyCard('));
    expect(dialog, contains('AgentOrchestrationModelLibraryPolicyCard('));
    expect(dialog, isNot(contains('class _RenamePolicyDialog')));
  });
}
