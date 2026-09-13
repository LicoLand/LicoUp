import 'conversation_execution.dart';
import 'package:licoup/src/contracts/agent_conversation_attachment.dart';
import 'package:licoup/src/contracts/agent_dispatch_lane.dart';

/// Stable failure exposed by the platform without process or transport details.
final class NativeConversationException implements Exception {
  const NativeConversationException(this.code);

  final String code;

  @override
  String toString() => 'NativeConversationException($code)';
}

final class AgentConversationSessionScope {
  const AgentConversationSessionScope({
    required this.agentId,
    this.sessionId = '',
  });

  final String agentId;
  final String sessionId;
}

sealed class AgentConversationTurnScope {
  const AgentConversationTurnScope();
}

final class AgentSessionTurnScope extends AgentConversationTurnScope {
  const AgentSessionTurnScope({required this.session, this.turnId = ''});

  final AgentConversationSessionScope session;
  final String turnId;
}

final class PersistentConversationTurnScope extends AgentConversationTurnScope {
  const PersistentConversationTurnScope({
    required this.turnHandle,
    required this.conversationId,
  });

  final String turnHandle;
  final String conversationId;
}

/// Canonical action payloads retain their native-owned domain schema. This
/// envelope carries semantic content only; it cannot carry CLI arguments.
final class ClientConversationCommand {
  ClientConversationCommand(Map<String, dynamic> payload)
    : payload = Map<String, dynamic>.unmodifiable(payload);

  final Map<String, dynamic> payload;
  String get action => (payload['action'] ?? '').toString();
}

abstract interface class ClientConversationNativePort {
  Future<Map<String, dynamic>> executeClientConversation(
    ClientConversationCommand command,
  );
}

/// Named conversation operations keep generated RPC methods and encoding inside
/// the platform adapter. Result payloads remain opaque native data until the
/// owning service projects them into AgentDispatch results and events.
abstract interface class AgentConversationNativePort {
  Future<Map<String, dynamic>> open(
    AgentConversationSessionScope session, {
    AgentDispatchBind bind = const AgentDispatchBind(),
  });

  Stream<Map<String, dynamic>> send(
    AgentConversationSessionScope session, {
    required String text,
    List<ConversationAttachment> attachments = const [],
    AgentDispatchBind bind = const AgentDispatchBind(),
  });

  Future<Map<String, dynamic>> active({
    required String agentId,
    String sessionId = '',
    String conversationId = '',
    Duration waitForChange = Duration.zero,
  });

  Stream<Map<String, dynamic>> attach(
    PersistentConversationTurnScope turn, {
    int afterCursor = 0,
  });

  Future<Map<String, dynamic>> steer(
    AgentConversationTurnScope turn, {
    required String text,
    AgentDispatchBind bind = const AgentDispatchBind(),
  });

  Future<Map<String, dynamic>> cancel(AgentConversationTurnScope turn);

  Future<Map<String, dynamic>> cleanup(AgentConversationSessionScope session);

  Future<Map<String, dynamic>> capabilities(
    String agentId, {
    AgentDispatchBind bind = const AgentDispatchBind(),
  });
}

abstract interface class ConversationNativePort
    implements AgentConversationNativePort, ClientConversationNativePort {}

/// Read-only raw execution access supported only by the desktop native host.
abstract interface class ConversationExecutionNativePort {
  Stream<Map<String, dynamic>> execution(
    ConversationExecutionReference reference, {
    int afterCursor = 0,
  });
}
