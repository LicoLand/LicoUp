import 'package:flutter_client/src/contracts/routing/distillation/distillation_package_models.dart';
import 'package:flutter_client/src/contracts/routing/distillation/distillation_usage_audit.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('usage aggregation is additive and preserves total accounting', () {
    const first = DistillationUsage(
      dispatchCallCount: 1,
      promptTokens: 10,
      completionTokens: 5,
      totalTokens: 15,
    );
    const second = DistillationUsage(
      dispatchCallCount: 2,
      promptTokens: 20,
      completionTokens: 8,
      totalTokens: 28,
    );

    expect((first + second).toJson(), {
      'dispatchCallCount': 3,
      'promptTokens': 30,
      'completionTokens': 13,
      'totalTokens': 43,
    });
  });

  test('audit projection contains references but has no turn field', () {
    const package = DistillationPackage(
      objective: 'ship routing',
      currentState: 'ready',
      decisions: ['use policy'],
      constraints: ['local only'],
      openItems: ['verify'],
      sourceSessionId: 'source',
      sourceAgentId: 'agent',
      createdAt: 'now',
    );
    const audit = DistillationAuditRecord(
      sourceSessionId: 'source',
      sourceAgentId: 'agent',
      distillerAgentId: 'distiller',
      package: package,
      fidelity: FidelityCheckResult(
        passed: true,
        checkedSections: ['objective'],
        missingSections: [],
      ),
      usage: DistillationUsage(totalTokens: 3),
      createdAt: 'now',
    );

    final json = audit.toJson();
    expect(json['sourceSessionId'], 'source');
    expect(json.containsKey('turns'), isFalse);
    expect(json.containsKey('sourceText'), isFalse);
    expect(const DistillationAuditRecord.empty().isEmpty, isTrue);
  });
}
