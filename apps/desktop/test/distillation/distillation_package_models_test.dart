import 'package:flutter_client/src/contracts/routing/distillation/distillation_package_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('package JSON normalization and section presence stay local', () {
    final package = DistillationPackage.fromJson({
      'objective': '  ship routing  ',
      'currentState': 'ready',
      'decisions': ' use policy ',
      'constraints': [' privacy ', '', '  '],
      'openItems': <Object?>[' tests ', null],
      'sourceSessionId': ' source ',
      'sourceAgentId': ' agent ',
      'createdAt': ' now ',
    });

    expect(package.objective, 'ship routing');
    expect(package.decisions, ['use policy']);
    expect(package.constraints, ['privacy']);
    expect(package.openItems, ['tests', 'null']);
    expect(package.hasObjective, isTrue);
    expect(package.hasCurrentState, isTrue);
    expect(package.hasDecisions, isTrue);
    expect(package.hasConstraints, isTrue);
    expect(package.hasOpenItems, isTrue);
    expect(package.sourceSessionId, 'source');
    expect(package.toJson()['objective'], 'ship routing');
    expect(package.estimatedLength, greaterThan(0));
  });

  test('fidelity result serializes grounded and uncovered projections', () {
    const result = FidelityCheckResult(
      passed: false,
      checkedSections: ['objective'],
      missingSections: [],
      groundedSections: ['objective'],
      uncoveredSections: ['constraints'],
      message: 'failed',
    );

    expect(result.toJson(), {
      'passed': false,
      'checkedSections': ['objective'],
      'missingSections': const [],
      'groundedSections': ['objective'],
      'uncoveredSections': ['constraints'],
      'message': 'failed',
    });
  });
}
