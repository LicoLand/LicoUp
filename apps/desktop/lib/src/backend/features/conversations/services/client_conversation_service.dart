import 'package:licoup/src/contracts/conversation_native_port.dart';

final class ClientConversationServiceFailure implements Exception {
  const ClientConversationServiceFailure(this.code);

  final String code;

  @override
  String toString() => code;
}

final class ClientConversationService {
  const ClientConversationService({
    required ClientConversationNativePort native,
  }) : _native = native;

  final ClientConversationNativePort _native;

  Future<Object?> execute(Map<String, dynamic> request) async {
    final Map<String, dynamic> output;
    try {
      output = await _native.executeClientConversation(
        ClientConversationCommand(request),
      );
    } on NativeConversationException catch (error) {
      throw ClientConversationServiceFailure(error.code);
    }
    if (output['ok'] != true) {
      final error = output['error'];
      final code = error is Map
          ? (error['code'] ?? 'conversation_operation_failed').toString()
          : 'conversation_operation_failed';
      throw ClientConversationServiceFailure(code);
    }
    return output['result'];
  }
}
