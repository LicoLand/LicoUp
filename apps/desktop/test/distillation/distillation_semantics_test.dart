import 'package:flutter_client/src/contracts/routing/distillation/distillation_semantics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('semantic section detection supports English and Chinese cues', () {
    expect(
      distillationSemanticSections(
        'Goal: ship. Current state: ready. Decision: adopt a queue. '
        'Constraint: must stay local. Next step: verify.',
      ),
      containsAll({
        'objective',
        'currentState',
        'decisions',
        'constraints',
        'openItems',
      }),
    );
    expect(
      distillationSemanticSections('目标完成路由。正在验证。决定采用队列。严禁上传。下一步验收。'),
      containsAll({
        'objective',
        'currentState',
        'decisions',
        'constraints',
        'openItems',
      }),
    );
  });

  test('anchors discard labels while retaining grounded identifiers', () {
    final anchors = distillationSemanticAnchors(
      'Objective: preserve routing_policy and hot-reload. 采用有界窗口。',
    );
    expect(anchors, containsAll(['routing_policy', 'hot-reload', '采用', '有界']));
    expect(anchors, isNot(contains('objective')));
  });
}
