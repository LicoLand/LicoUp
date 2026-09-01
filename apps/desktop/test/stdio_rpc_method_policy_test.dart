import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/method_policy.dart';

void main() {
  test('definition queries stay off the conversation sidecar', () {
    expect(
      stdioRpcMethodUsesConversationLane('strategy.execute', {
        'action': 'strategy.definition.list',
      }),
      isFalse,
    );
    expect(
      stdioRpcMethodUsesConversationLane('strategy.execute', {
        'action': 'strategy.definition.inspect',
      }),
      isFalse,
    );
  });

  test(
    'only run-driving strategy actions stay on the conversation sidecar',
    () {
      for (final action in [
        'strategy.run.start',
        'strategy.run.resume',
        'strategy.run.retry',
      ]) {
        expect(
          stdioRpcMethodUsesConversationLane('strategy.execute', {
            'action': action,
          }),
          isTrue,
        );
      }
      for (final action in [
        'strategy.run.active',
        'strategy.run.inspect',
        'strategy.run.cancel',
      ]) {
        expect(
          stdioRpcMethodUsesConversationLane('strategy.execute', {
            'action': action,
          }),
          isFalse,
        );
      }
    },
  );

  test('posted messages persist off the sidecar; after-post is unbounded', () {
    expect(
      stdioRpcMethodIsUnboundedClientTurn('client.conversation.execute', {
        'action': 'conversation.message.post',
      }),
      isFalse,
    );
    expect(
      stdioRpcMethodIsUnboundedClientTurn('client.conversation.execute', {
        'action': 'conversation.dispatch.after-post',
      }),
      isTrue,
    );
    expect(
      stdioRpcMethodUsesConversationLane('client.conversation.execute'),
      isFalse,
    );
  });
}
