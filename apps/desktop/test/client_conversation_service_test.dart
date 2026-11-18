import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/backend/features/conversations/services/client_conversation_service.dart';
import 'package:licoup/src/contracts/conversation_native_port.dart';

void main() {
  test(
    'passes canonical action and content through the semantic port',
    () async {
      final native = _ConversationNativePort();
      final service = ClientConversationService(native: native);
      final request = <String, dynamic>{
        'action': 'conversation.message.post',
        'conversationId': 'conversation:synthetic',
        'authorMembershipId': 'membership:owner',
        'content': 'Line one\n"quoted" content',
      };

      expect(await service.execute(request), {'eventId': 'event:posted'});
      expect(native.command?.action, 'conversation.message.post');
      expect(native.command?.payload, request);
    },
  );

  test('preserves the typed native failure code', () async {
    final native = _ConversationNativePort()
      ..failure = const NativeConversationException('transport_closed');
    final service = ClientConversationService(native: native);

    await expectLater(
      service.execute({'action': 'conversation.get'}),
      throwsA(
        isA<ClientConversationServiceFailure>().having(
          (error) => error.code,
          'code',
          'transport_closed',
        ),
      ),
    );
  });

  test('preserves a failed canonical response code', () async {
    final native = _ConversationNativePort()
      ..response = {
        'ok': false,
        'error': {'code': 'conversation_not_found'},
      };
    final service = ClientConversationService(native: native);

    await expectLater(
      service.execute({'action': 'conversation.get'}),
      throwsA(
        isA<ClientConversationServiceFailure>().having(
          (error) => error.code,
          'code',
          'conversation_not_found',
        ),
      ),
    );
  });
}

final class _ConversationNativePort implements ClientConversationNativePort {
  ClientConversationCommand? command;
  NativeConversationException? failure;
  Map<String, dynamic> response = {
    'ok': true,
    'result': {'eventId': 'event:posted'},
  };

  @override
  Future<Map<String, dynamic>> executeClientConversation(
    ClientConversationCommand command,
  ) async {
    this.command = command;
    final failure = this.failure;
    if (failure != null) throw failure;
    return response;
  }
}
