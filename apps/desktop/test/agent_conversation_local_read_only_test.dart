import 'package:licoup/src/application/features/agents/conversation/agent_conversation_read_only_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native history policy states the local read-only responsibility', () {
    expect(nativeConversationReadOnlyMessageZh, contains('LicoUp'));
    expect(nativeConversationReadOnlyMessageZh, contains('本机只读'));
    expect(nativeConversationReadOnlyMessageZh, contains('不会修改或删除源智能体会话'));
    expect(nativeConversationReadOnlyMessageEn, contains('on this device'));
    expect(nativeConversationReadOnlyMessageZh, isNot(contains('LicoMesh')));
    expect(nativeConversationReadOnlyMessageEn, isNot(contains('LicoMesh')));
  });
}
