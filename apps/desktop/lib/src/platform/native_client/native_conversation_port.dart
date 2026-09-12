import 'package:licoup/src/contracts/agent_conversation_attachment.dart';
import 'package:licoup/src/contracts/agent_dispatch_lane.dart';
import 'package:licoup/src/contracts/conversation_native_port.dart';
import 'package:licoup/src/contracts/generated/conversation_protocol.g.dart';
import 'package:licoup/src/platform/native_client/native_cli_ports.dart';

/// Desktop conversation adapter. Every operation uses the owned structured
/// transport even when stateless commands use an injected one-shot executor.
/// Mobile conversation dispatch stays on its secure relay/FFI gateway.
final class StdioConversationNativePort implements ConversationNativePort {
  const StdioConversationNativePort({
    required NativeStdioRpcTransport transport,
    required bool desktopRuntime,
  }) : _transport = transport,
       _desktopRuntime = desktopRuntime;

  final NativeStdioRpcTransport _transport;
  final bool _desktopRuntime;

  @override
  Future<Map<String, dynamic>> open(
    AgentConversationSessionScope session, {
    AgentDispatchBind bind = const AgentDispatchBind(),
  }) => _execute(ConversationProtocolMethod.agentConversationOpen, {
    ..._sessionFields(session),
    ..._bindFields(bind),
  });

  @override
  Stream<Map<String, dynamic>> send(
    AgentConversationSessionScope session, {
    required String text,
    List<ConversationAttachment> attachments = const [],
    AgentDispatchBind bind = const AgentDispatchBind(),
  }) => _stream(ConversationProtocolMethod.agentConversationSend, {
    ..._sessionFields(session),
    'text': text,
    'streamEvents': true,
    // Zero selects native writable policy; the observer adds no deadline.
    'timeoutMs': 0,
    if (attachments.isNotEmpty)
      'attachments': [
        for (final attachment in attachments) attachment.toJson(),
      ],
    ..._bindFields(bind),
    if (bind.acceptanceMode.trim().isNotEmpty)
      'acceptanceMode': bind.acceptanceMode.trim(),
  });

  @override
  Future<Map<String, dynamic>> active({
    required String agentId,
    String sessionId = '',
    String conversationId = '',
    Duration waitForChange = Duration.zero,
  }) => _execute(ConversationProtocolMethod.agentConversationActive, {
    'agent': agentId.trim(),
    if (sessionId.trim().isNotEmpty) 'sessionId': sessionId.trim(),
    if (conversationId.trim().isNotEmpty)
      'conversationId': conversationId.trim(),
    if (waitForChange > Duration.zero)
      'waitForChangeMs': waitForChange.inMilliseconds.clamp(0, 2000),
  });

  @override
  Stream<Map<String, dynamic>> attach(
    PersistentConversationTurnScope turn, {
    int afterCursor = 0,
  }) => _stream(ConversationProtocolMethod.agentConversationAttach, {
    ..._turnFields(turn),
    'afterCursor': afterCursor,
  });

  @override
  Future<Map<String, dynamic>> steer(
    AgentConversationTurnScope turn, {
    required String text,
    AgentDispatchBind bind = const AgentDispatchBind(),
  }) => _execute(ConversationProtocolMethod.agentConversationSteer, {
    ..._turnFields(turn),
    'text': text.trim(),
    ..._bindFields(bind),
  });

  @override
  Future<Map<String, dynamic>> cancel(AgentConversationTurnScope turn) =>
      _execute(
        ConversationProtocolMethod.agentConversationCancel,
        _turnFields(turn),
      );

  @override
  Future<Map<String, dynamic>> cleanup(AgentConversationSessionScope session) =>
      _execute(
        ConversationProtocolMethod.agentConversationCleanup,
        _sessionFields(session),
      );

  @override
  Future<Map<String, dynamic>> capabilities(
    String agentId, {
    AgentDispatchBind bind = const AgentDispatchBind(),
  }) => _execute(ConversationProtocolMethod.agentConversationCapabilities, {
    'agent': agentId.trim(),
    if (bind.runtimeConnection.isNotEmpty)
      'runtimeConnection': bind.runtimeConnection,
  });

  @override
  Future<Map<String, dynamic>> executeClientConversation(
    ClientConversationCommand command,
  ) => _execute(
    ConversationProtocolMethod.clientConversationExecute,
    command.payload,
  );

  Future<Map<String, dynamic>> _execute(
    ConversationProtocolMethod method,
    Map<String, dynamic> params,
  ) async {
    _requireDesktop();
    try {
      return await _transport.executeStructured(method.wireName, params);
    } on LicoClientRpcException catch (error) {
      throw NativeConversationException(error.code);
    } on Object {
      throw const NativeConversationException('transport_failed');
    }
  }

  Stream<Map<String, dynamic>> _stream(
    ConversationProtocolMethod method,
    Map<String, dynamic> params,
  ) async* {
    _requireDesktop();
    try {
      await for (final event in _transport.streamConversation({
        ...params,
        '_rpcOperation': method.wireName.substring(
          'agent.conversation.'.length,
        ),
      })) {
        yield event;
      }
    } on LicoClientRpcException catch (error) {
      throw NativeConversationException(error.code);
    } on Object {
      throw const NativeConversationException('transport_failed');
    }
  }

  void _requireDesktop() {
    if (!_desktopRuntime) {
      throw const NativeConversationException(
        'local_conversation_runtime_unavailable',
      );
    }
  }
}

Map<String, dynamic> _sessionFields(AgentConversationSessionScope session) => {
  'agent': session.agentId.trim(),
  if (session.sessionId.trim().isNotEmpty)
    'sessionId': session.sessionId.trim(),
};

Map<String, dynamic> _turnFields(AgentConversationTurnScope turn) =>
    switch (turn) {
      AgentSessionTurnScope() => {
        ..._sessionFields(turn.session),
        if (turn.turnId.trim().isNotEmpty) 'turnId': turn.turnId.trim(),
      },
      PersistentConversationTurnScope() => {
        'turnHandle': turn.turnHandle.trim(),
        'conversationId': turn.conversationId.trim(),
      },
    };

Map<String, dynamic> _bindFields(AgentDispatchBind bind) => {
  if (bind.permissionMode.trim().isNotEmpty)
    'permissionMode': bind.permissionMode.trim(),
  if (bind.allowedTools.isNotEmpty)
    'allowedTools': List<String>.unmodifiable(bind.allowedTools),
  if (bind.sessionPath.trim().isNotEmpty)
    'sessionPath': bind.sessionPath.trim(),
  if (bind.workingDirectory.trim().isNotEmpty)
    'workingDirectory': bind.workingDirectory.trim(),
  if (bind.binaryPath.trim().isNotEmpty) 'binaryPath': bind.binaryPath.trim(),
  if (bind.model.trim().isNotEmpty) 'model': bind.model.trim(),
  if (bind.reasoningEffort.trim().isNotEmpty)
    'reasoningEffort': bind.reasoningEffort.trim(),
  if (bind.licoProfile.trim().isNotEmpty)
    'licoProfile': bind.licoProfile.trim(),
  if (bind.runtimeConnection.isNotEmpty)
    'runtimeConnection': bind.runtimeConnection,
};
