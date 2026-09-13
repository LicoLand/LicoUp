import 'package:licoup/src/contracts/conversation_native_port.dart';
import 'package:licoup/src/contracts/generated/conversation_protocol.g.dart';
import 'package:licoup/src/platform/native_client/native_cli_ports.dart';
import 'package:licoup/src/platform/native_client/native_conversation_port.dart';

typedef ConversationCommandFixture =
    Future<Map<String, dynamic>> Function(
      ConversationProtocolMethod method,
      Map<String, dynamic> params,
    );
typedef ConversationStreamFixture =
    Stream<Map<String, dynamic>> Function(
      ConversationProtocolMethod method,
      Map<String, dynamic> params,
    );

/// Synthetic native frame peer. Service fixtures exercise the real semantic
/// platform adapter while this peer supplies responses without a CLI process.
class FakeConversationTransport implements NativeStdioRpcTransport {
  FakeConversationTransport({this.command, this.events});

  final ConversationCommandFixture? command;
  final ConversationStreamFixture? events;
  final List<({ConversationProtocolMethod method, Map<String, dynamic> params})>
  requests = [];

  ConversationNativePort get native =>
      StdioConversationNativePort(transport: this, desktopRuntime: true);

  @override
  Future<Map<String, dynamic>> execute(List<String> arguments) =>
      throw StateError('conversation fixture rejects CLI arguments');

  @override
  Future<Map<String, dynamic>> executeStructured(
    String method,
    Map<String, dynamic> params,
  ) {
    final typed = ConversationProtocolMethod.fromWire(method)!;
    requests.add((method: typed, params: Map.unmodifiable(params)));
    return command?.call(typed, params) ?? Future.value({'ok': true});
  }

  @override
  Stream<Map<String, dynamic>> streamConversation(
    Map<String, dynamic> request,
  ) {
    final params = Map<String, dynamic>.from(request);
    final operation = params.remove('_rpcOperation') ?? 'send';
    final method = ConversationProtocolMethod.fromWire(
      'agent.conversation.$operation',
    )!;
    requests.add((method: method, params: Map.unmodifiable(params)));
    return events?.call(method, params) ?? const Stream.empty();
  }

  @override
  Future<void> dispose() async {}
}
