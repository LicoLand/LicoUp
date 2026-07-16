import 'package:flutter_client/src/contracts/routing/distillation/distillation_package_models.dart';
import 'package:flutter_client/src/contracts/routing/distillation/distillation_result_models.dart';
import 'package:flutter_client/src/contracts/routing/distillation/distillation_usage_audit.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('success and failure expose typed bounded projections', () {
    const package = DistillationPackage(
      objective: 'goal',
      currentState: '',
      decisions: [],
      constraints: [],
      openItems: [],
      sourceSessionId: 'source',
      sourceAgentId: 'agent',
      createdAt: 'now',
    );
    const fidelity = FidelityCheckResult(
      passed: true,
      checkedSections: ['objective'],
      missingSections: [],
    );
    const usage = DistillationUsage(totalTokens: 9);
    const DistillationResult success = DistillationSuccess(
      package: package,
      fidelity: fidelity,
      usage: usage,
      distillerAgentId: 'distiller',
    );
    const DistillationResult failure = DistillationFailure(
      reason: 'failed closed',
      retriesExhausted: true,
      usage: usage,
    );

    final successProjection = success as DistillationSuccess;
    final failureProjection = failure as DistillationFailure;
    expect(successProjection.package, same(package));
    expect(successProjection.usage.totalTokens, 9);
    expect(failureProjection.reason, 'failed closed');
    expect(failureProjection.retriesExhausted, isTrue);
  });
}
