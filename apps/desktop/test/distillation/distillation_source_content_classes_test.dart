import 'package:flutter_client/src/contracts/routing/distillation/distillation_input_window.dart';
import 'package:flutter_client/src/contracts/routing/distillation/distillation_source_content_classes.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('content classes retain bilingual semantic anchors by section', () {
    final classes = DistillationSourceContentClasses.detect(const [
      DistillationConversationTurn(role: 'user', text: '我们需要完成路由交接'),
      DistillationConversationTurn(role: 'assistant', text: '协调器正在测试中'),
      DistillationConversationTurn(role: 'assistant', text: '我们决定采用有界窗口'),
      DistillationConversationTurn(role: 'user', text: '原始对话不得写入审计'),
      DistillationConversationTurn(role: 'assistant', text: '下一步补齐产品测试'),
    ]);

    expect(classes.hasObjective, isTrue);
    expect(classes.hasCurrentState, isTrue);
    expect(classes.hasDecisions, isTrue);
    expect(classes.hasConstraints, isTrue);
    expect(classes.hasOpenItems, isTrue);
    expect(classes.semanticAnchors['decisions'], contains('有界'));
  });

  test('role fallbacks infer objective and current state without labels', () {
    final classes = DistillationSourceContentClasses.detect(const [
      DistillationConversationTurn(role: 'user', text: 'route handoff'),
      DistillationConversationTurn(role: 'assistant', text: 'broker ready'),
    ]);

    expect(classes.hasObjective, isTrue);
    expect(classes.hasCurrentState, isTrue);
    expect(classes.semanticAnchors['objective'], contains('route'));
    expect(classes.semanticAnchors['currentState'], contains('broker'));
  });
}
