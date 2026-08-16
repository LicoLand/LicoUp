import 'dart:async';
import 'dart:io';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/backend/features/agents/services/agent_conversation_service.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/agent_conversation_attachment.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/platform/native_client/agent_service.dart';

final acceptanceAgentId = _safeEnvironmentValue(
  'LICO_AGENT_CONVERSATION_PRODUCT_AGENT',
  'codex',
);
final acceptanceAgentModel = _safeEnvironmentValue(
  'LICO_AGENT_CONVERSATION_PRODUCT_MODEL',
  _verificationModelForAgent(acceptanceAgentId),
  allowSpaces: true,
);
const acceptanceNativeSessionId = 'acceptance-native-session';

ClientController createAcceptanceController(
  AcceptanceConversationService conversationService,
) {
  return ClientController(conversationService: conversationService)
    ..currentSection = ClientSection.agents
    ..scannedTargets = [acceptanceAgentTarget]
    ..selectedConversationAgentId = acceptanceAgentId
    ..conversationModelsByAgent = {acceptanceAgentId: acceptanceAgentModel};
}

final acceptanceAgentTarget = TargetCandidate(
  target: acceptanceAgentId,
  label: 'Acceptance agent',
  kind: 'native-history',
  status: 'detected',
  configured: true,
  confidence: 1,
  binaryPath: '/synthetic/bin/$acceptanceAgentId',
  adapterStatus: 'implemented',
  adapterCapabilities: const {
    'conversationDriver': 'implemented',
    'conversationReadiness': 'ready',
    'conversationConsecutivePasses': 3,
  },
  supportedActions: const ['runtime.message.send'],
  modelCatalog: {
    'status': 'available',
    'models': [
      {'name': acceptanceAgentModel, 'reasoningEfforts': <String>[]},
    ],
  },
);

class AcceptanceConversationService extends AgentConversationService {
  final List<AcceptanceRequest> requests = [];
  final List<AgentConversationMessage> _messages = [];
  _AcceptanceActiveTurn? _activeTurn;
  int historyReadCount = 0;

  Future<void> completeActiveTurn() async {
    final active = _activeTurn;
    if (active == null) {
      throw StateError('acceptance_active_turn_missing');
    }
    final completedReply = '${active.replyPrefix} complete';
    final now = DateTime.utc(
      2026,
      7,
      14,
      12,
      0,
      active.turnNumber,
    ).toIso8601String();
    _messages.addAll([
      AgentConversationMessage(
        id: '${active.turnId}-user',
        role: 'user',
        text: active.request.text,
        createdAt: now,
      ),
      AgentConversationMessage(
        id: '${active.turnId}-assistant',
        role: 'assistant',
        text: completedReply,
        createdAt: now,
      ),
    ]);
    active.controller.add(
      AgentDispatchEvent(
        kind: 'agent.message.completed',
        sessionId: acceptanceNativeSessionId,
        turnId: active.turnId,
        payload: {'text': completedReply},
      ),
    );
    active.controller.add(
      AgentDispatchEvent(
        kind: 'dispatch.turn.completed',
        sessionId: acceptanceNativeSessionId,
        turnId: active.turnId,
        payload: {
          'ok': true,
          'nativeSessionId': acceptanceNativeSessionId,
          'turnStatus': 'completed',
          'effective': {'model': acceptanceAgentModel},
        },
      ),
    );
    await active.controller.close();
    _activeTurn = null;
  }

  @override
  Stream<AgentConversationSession> streamSessions({
    required AgentCommandRunner agentService,
    required String agentId,
    String sessionId = '',
    int? limit,
    int offset = 0,
    AgentDispatchBind bind = const AgentDispatchBind(),
  }) async* {
    historyReadCount += 1;
    if (_messages.isNotEmpty &&
        (sessionId.isEmpty || sessionId == acceptanceNativeSessionId)) {
      yield _session();
    }
  }

  @override
  Future<List<AgentConversationSession>> loadSessions({
    required AgentCommandRunner agentService,
    required String agentId,
    String sessionId = '',
    int? limit,
    int offset = 0,
    AgentDispatchBind bind = const AgentDispatchBind(),
  }) async {
    historyReadCount += 1;
    if (_messages.isEmpty ||
        (sessionId.isNotEmpty && sessionId != acceptanceNativeSessionId)) {
      return const [];
    }
    return [_session()];
  }

  @override
  Stream<AgentDispatchEvent> sendStreaming({
    required AgentCommandRunner runner,
    required String agentId,
    required String text,
    required String sessionId,
    List<ConversationAttachment> attachments = const [],
    AgentDispatchBind bind = const AgentDispatchBind(),
  }) {
    if (agentId != acceptanceAgentId) {
      throw StateError('acceptance_agent_mismatch');
    }
    if (_activeTurn != null) {
      throw StateError('acceptance_turn_already_active');
    }
    final turnNumber = requests.length + 1;
    final request = AcceptanceRequest(
      text: text,
      sessionId: sessionId,
      model: bind.model,
    );
    requests.add(request);
    final replyPrefix = turnNumber == 1 ? 'stream-one' : 'stream-two';
    final turnId = 'acceptance-turn-$turnNumber';
    final controller = StreamController<AgentDispatchEvent>(sync: true);
    _activeTurn = _AcceptanceActiveTurn(
      controller: controller,
      request: request,
      turnNumber: turnNumber,
      turnId: turnId,
      replyPrefix: replyPrefix,
    );
    scheduleMicrotask(() {
      controller.add(
        AgentDispatchEvent(
          kind: 'dispatch.turn.started',
          sessionId: sessionId,
          turnId: turnId,
          payload: const {'status': 'running'},
        ),
      );
      controller.add(
        AgentDispatchEvent(
          kind: 'agent.message.chunk',
          sessionId: acceptanceNativeSessionId,
          turnId: turnId,
          payload: {'text': replyPrefix},
        ),
      );
    });
    return controller.stream;
  }

  AgentConversationSession _session() {
    return AgentConversationSession(
      id: 'acceptance-history-row',
      nativeSessionId: acceptanceNativeSessionId,
      agentId: acceptanceAgentId,
      title: 'Acceptance conversation',
      createdAt: '2026-07-14T12:00:00.000Z',
      updatedAt: '2026-07-14T12:00:02.000Z',
      adapterId: 'codex-app-server',
      sourceKind: 'native-acceptance',
      native: true,
      readOnly: true,
      messageCount: _messages.length,
      messages: List.unmodifiable(_messages),
    );
  }
}

String _safeEnvironmentValue(
  String name,
  String fallback, {
  bool allowSpaces = false,
}) {
  final value = Platform.environment[name]?.trim() ?? '';
  if (value.isEmpty) return fallback;
  final pattern = allowSpaces
      ? RegExp(r'^[A-Za-z0-9._ +:/-]{1,80}$')
      : RegExp(r'^[a-z0-9-]{1,64}$');
  if (!pattern.hasMatch(value)) {
    throw StateError('acceptance_environment_invalid');
  }
  return value;
}

/// Reads `tools/scripts/config/agent-conversation-verification-models.toml`.
/// Keeps product-e2e defaults aligned with the Node verification gates.
String _verificationModelForAgent(String agentId) {
  final candidates = <String>[
    if (Platform.script.scheme == 'file')
      File.fromUri(
        Platform.script.resolve(
          '../../../tools/scripts/config/'
          'agent-conversation-verification-models.toml',
        ),
      ).path,
    '${Directory.current.path}/tools/scripts/config/'
        'agent-conversation-verification-models.toml',
    '${Directory.current.path}/../../tools/scripts/config/'
        'agent-conversation-verification-models.toml',
  ];
  final file = candidates
      .map(File.new)
      .cast<File?>()
      .firstWhere((candidate) => candidate!.existsSync(), orElse: () => null);
  if (file == null) {
    throw StateError('verification_models_missing');
  }
  final keyPattern = RegExp(
    '^\\s*(?:${RegExp.escape(agentId)}|"${RegExp.escape(agentId)}")'
    '\\s*=\\s*"([^"]+)"\\s*\$',
    multiLine: true,
  );
  final match = keyPattern.firstMatch(file.readAsStringSync());
  final model = match?.group(1)?.trim() ?? '';
  if (model.isEmpty) {
    throw StateError('verification_model_missing:$agentId');
  }
  return model;
}

class AcceptanceRequest {
  const AcceptanceRequest({
    required this.text,
    required this.sessionId,
    required this.model,
  });

  final String text;
  final String sessionId;
  final String model;
}

class _AcceptanceActiveTurn {
  const _AcceptanceActiveTurn({
    required this.controller,
    required this.request,
    required this.turnNumber,
    required this.turnId,
    required this.replyPrefix,
  });

  final StreamController<AgentDispatchEvent> controller;
  final AcceptanceRequest request;
  final int turnNumber;
  final String turnId;
  final String replyPrefix;
}
