/// Unified agent conversation dispatch lane (REQ-ACD-001).
///
/// Production callers (direct, orchestrated, mobile-relay) must use this
/// contract instead of one-shot `agent message send` stdin forks.
/// Implementation is owned by [AgentConversationService] once the Dart
/// dispatch implementation node lands; this file is the architecture scaffold.
library;

import 'package:flutter_client/src/contracts/agent_command_runner.dart';

/// Working-directory / binary / model bind for a dispatch call.
final class AgentDispatchBind {
  const AgentDispatchBind({
    this.workingDirectory = '',
    this.binaryPath = '',
    this.sessionPath = '',
    this.model = '',
    this.reasoningEffort = '',
  });

  final String workingDirectory;
  final String binaryPath;
  final String sessionPath;
  final String model;
  final String reasoningEffort;
}

final class AgentDispatchSession {
  const AgentDispatchSession({
    required this.sessionId,
    this.threadId = '',
    this.agentId = '',
  });

  final String sessionId;
  final String threadId;
  final String agentId;
}

final class AgentDispatchTurnResult {
  const AgentDispatchTurnResult({
    required this.ok,
    this.sessionId = '',
    this.turnId = '',
    this.status = '',
    this.errorCode = '',
    this.errorMessage = '',
    this.raw = const <String, dynamic>{},
  });

  final bool ok;
  final String sessionId;
  final String turnId;
  final String status;
  final String errorCode;
  final String errorMessage;

  /// Sidecar payload for callers that still inspect effective settings.
  final Map<String, dynamic> raw;
}

final class AgentDispatchCancelResult {
  const AgentDispatchCancelResult({
    required this.ok,
    this.status = '',
    this.errorCode = '',
  });

  final bool ok;
  final String status;
  final String errorCode;
}

/// Per-agent lane capability matrix (CL-06 C-01..C-06 plus lane metadata).
final class AgentDispatchCapabilities {
  const AgentDispatchCapabilities({
    required this.agentId,
    this.laneKind = '',
    this.runtimeProtocol = '',
    this.blockerCodes = const <String>[],
    this.streaming = false,
    this.reasoningTrace = false,
    this.approval = false,
    this.attachments = false,
    this.interruptSteer = false,
    this.usageStatus = false,
    this.exactResume = false,
  });

  final String agentId;
  final String laneKind;
  final String runtimeProtocol;
  final List<String> blockerCodes;
  final bool streaming;
  final bool reasoningTrace;
  final bool approval;
  final bool attachments;
  final bool interruptSteer;
  final bool usageStatus;
  final bool exactResume;
}

/// Semantic dispatch event; maps into the conversation event model in callers.
final class AgentDispatchEvent {
  const AgentDispatchEvent({
    required this.kind,
    this.sessionId = '',
    this.turnId = '',
    this.payload = const <String, dynamic>{},
  });

  final String kind;
  final String sessionId;
  final String turnId;
  final Map<String, dynamic> payload;
}

/// Single dispatch lane for all conversation send paths.
abstract class AgentDispatchLane {
  Future<AgentDispatchSession> openOrResume({
    required AgentCommandRunner runner,
    required String agentId,
    String sessionId = '',
    AgentDispatchBind bind = const AgentDispatchBind(),
  });

  Future<AgentDispatchTurnResult> send({
    required AgentCommandRunner runner,
    required String agentId,
    required String text,
    required String sessionId,
    AgentDispatchBind bind = const AgentDispatchBind(),
    String conversationReadiness = 'unverified',
    bool requireReady = true,
  });

  Stream<AgentDispatchEvent> stream({
    required AgentCommandRunner runner,
    required String agentId,
    required String sessionId,
    String turnId = '',
  });

  Future<AgentDispatchCancelResult> cancel({
    required AgentCommandRunner runner,
    required String agentId,
    required String sessionId,
    String turnId = '',
  });

  Future<AgentDispatchCapabilities> capabilities({
    required AgentCommandRunner runner,
    required String agentId,
    AgentDispatchBind bind = const AgentDispatchBind(),
    String conversationReadiness = 'unverified',
  });
}
