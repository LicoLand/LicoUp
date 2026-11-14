import 'package:presentation_contract/presentation_contract.dart';

sealed class AgentsIntent {
  const AgentsIntent({this.trace});

  final TraceContext? trace;
}

final class InitializeAcativa extends AgentsIntent {
  const InitializeAcativa({this.initialRevision = '', super.trace});

  final String initialRevision;
}

final class ImportAcativaPackage extends AgentsIntent {
  const ImportAcativaPackage(this.path, {super.trace});

  final String path;
}

final class SelectAcativaDefinition extends AgentsIntent {
  const SelectAcativaDefinition(this.revision, {super.trace});

  final String revision;
}

final class SaveAcativaActorBindings extends AgentsIntent {
  SaveAcativaActorBindings({
    required Iterable<AcativaAssignmentIntent> assignments,
    super.trace,
  }) : assignments = List<AcativaAssignmentIntent>.unmodifiable(assignments);

  final List<AcativaAssignmentIntent> assignments;
}

final class AcativaAssignmentIntent {
  const AcativaAssignmentIntent({
    required this.slotId,
    required this.ordinal,
    required this.agentId,
    required this.modelId,
    required this.reasoningEffort,
  });

  final String slotId;
  final int ordinal;
  final String agentId;
  final String modelId;
  final String reasoningEffort;
}

final class RefreshAcativaModelCatalogs extends AgentsIntent {
  RefreshAcativaModelCatalogs({required Iterable<String> agentIds, super.trace})
    : agentIds = List<String>.unmodifiable(agentIds);

  final List<String> agentIds;
}

final class ReadAcativaAssistantProfile extends AgentsIntent {
  const ReadAcativaAssistantProfile({super.trace});
}

final class UpdateAcativaAssistantProfile extends AgentsIntent {
  const UpdateAcativaAssistantProfile({
    required this.agentId,
    required this.modelId,
    required this.reasoningEffort,
    this.permissionMode,
    super.trace,
  });

  final String agentId;
  final String modelId;
  final String reasoningEffort;
  final String? permissionMode;
}

final class ScanAgents extends AgentsIntent {
  const ScanAgents({
    this.showProgress = true,
    this.forceRescanKnown = true,
    super.trace,
  });

  final bool showProgress;
  final bool forceRescanKnown;
}

final class SelectAgent extends AgentsIntent {
  const SelectAgent(this.agentId, {super.trace});

  final String agentId;
}

final class SelectAgentConversationSession extends AgentsIntent {
  const SelectAgentConversationSession({
    required this.agentId,
    required this.sessionId,
    this.nativeSessionId = '',
    super.trace,
  });

  final String agentId;
  final String sessionId;
  final String nativeSessionId;
}

/// Opens one native-history Agent session as the detail surface of a selected
/// Canonical group without changing that group's selection authority.
final class SelectGroupAgentConversationSession extends AgentsIntent {
  const SelectGroupAgentConversationSession({
    required this.groupConversationId,
    required this.agentId,
    required this.sessionId,
    this.nativeSessionId = '',
    super.trace,
  });

  final String groupConversationId;
  final String agentId;
  final String sessionId;
  final String nativeSessionId;
}

final class StartAgentConversation extends AgentsIntent {
  const StartAgentConversation(this.agentId, {super.trace});

  final String agentId;
}

/// Opens an Agent contact: the most recently updated top-level conversation,
/// or a fresh new-conversation home when none exists. Child sessions of a
/// sub-agent thread never count as the Agent's latest conversation.
final class OpenAgentConversation extends AgentsIntent {
  const OpenAgentConversation(this.agentId, {super.trace});

  final String agentId;
}

final class AddManualAgent extends AgentsIntent {
  AddManualAgent({
    required this.command,
    this.configPath = '',
    this.binaryPath = '',
    this.historyRoot = '',
    this.location = 'local',
    Map<String, dynamic> runtimeConnection = const <String, dynamic>{},
    super.trace,
  }) : runtimeConnection = Map<String, dynamic>.unmodifiable(runtimeConnection);

  final String command;
  final String configPath;
  final String binaryPath;
  final String historyRoot;
  final String location;
  final Map<String, dynamic> runtimeConnection;
}

final class ToggleAgentPinned extends AgentsIntent {
  const ToggleAgentPinned(this.agentId, {super.trace});

  final String agentId;
}

final class SelectAgentWorkingDirectory extends AgentsIntent {
  const SelectAgentWorkingDirectory(this.path, {super.trace});

  final String path;
}
