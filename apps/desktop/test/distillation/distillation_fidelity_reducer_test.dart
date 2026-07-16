import 'package:flutter_client/src/contracts/routing/distillation/distillation_fidelity_reducer.dart';
import 'package:flutter_client/src/contracts/routing/distillation/distillation_input_window.dart';
import 'package:flutter_client/src/contracts/routing/distillation/distillation_package_models.dart';
import 'package:flutter_client/src/contracts/routing/distillation/distillation_source_content_classes.dart';
import 'package:flutter_client/src/contracts/routing/routing_policy_schema.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const contract = RoutingFidelityContract(
    requiredSections: [
      'objective',
      'currentState',
      'decisions',
      'constraints',
      'openItems',
    ],
    maxPackageLength: 8192,
    retryOnFailure: true,
    maxRetries: 1,
  );
  const turns = [
    DistillationConversationTurn(role: 'user', text: '我们需要完成路由交接'),
    DistillationConversationTurn(role: 'assistant', text: '协调器正在测试中'),
    DistillationConversationTurn(role: 'assistant', text: '我们决定采用有界窗口'),
    DistillationConversationTurn(role: 'user', text: '原始对话不得写入审计'),
    DistillationConversationTurn(role: 'assistant', text: '下一步补齐产品测试'),
  ];

  test('source-grounded Chinese package passes all required sections', () {
    const package = DistillationPackage(
      objective: '完成路由交接',
      currentState: '协调器测试中',
      decisions: ['采用有界窗口'],
      constraints: ['不得写入原始对话'],
      openItems: ['补齐产品测试'],
      sourceSessionId: 'source',
      sourceAgentId: 'agent',
      createdAt: 'now',
    );
    final result = checkDistillationFidelity(
      package: package,
      contract: contract,
      sourceClasses: DistillationSourceContentClasses.detect(turns),
    );

    expect(result.passed, isTrue);
    expect(result.missingSections, isEmpty);
    expect(result.groundedSections, hasLength(5));
  });

  test(
    'missing and fabricated sections fail closed with exact projections',
    () {
      const package = DistillationPackage(
        objective: 'Publish an unrelated mobile feature.',
        currentState: 'Everything is complete.',
        decisions: ['Replace the policy system.'],
        constraints: [],
        openItems: ['Nothing remains.'],
        sourceSessionId: 'source',
        sourceAgentId: 'agent',
        createdAt: 'now',
      );
      final result = checkDistillationFidelity(
        package: package,
        contract: contract,
        sourceClasses: DistillationSourceContentClasses.detect(turns),
      );

      expect(result.passed, isFalse);
      expect(result.missingSections, contains('constraints'));
      expect(result.uncoveredSections, isNotEmpty);
      expect(result.message, contains('source-grounded'));
    },
  );

  test('package length is reduced before semantic success projection', () {
    final result = checkDistillationFidelity(
      package: DistillationPackage(
        objective: List.filled(20, 'route').join(),
        currentState: '',
        decisions: const [],
        constraints: const [],
        openItems: const [],
        sourceSessionId: 'source',
        sourceAgentId: 'agent',
        createdAt: 'now',
      ),
      contract: const RoutingFidelityContract(
        requiredSections: ['objective'],
        maxPackageLength: 16,
        retryOnFailure: false,
      ),
      sourceClasses: const DistillationSourceContentClasses(hasObjective: true),
    );

    expect(result.passed, isFalse);
    expect(result.message, contains('maxPackageLength 16'));
  });
}
