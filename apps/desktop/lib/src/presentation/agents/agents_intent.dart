import 'package:presentation_contract/presentation_contract.dart';

sealed class AgentsIntent {
  const AgentsIntent({this.trace});

  final TraceContext? trace;
}

final class InitializeAdaptiveFlywheel extends AgentsIntent {
  const InitializeAdaptiveFlywheel({this.initialRevision = '', super.trace});

  final String initialRevision;
}

final class ImportAdaptiveFlywheelPackage extends AgentsIntent {
  const ImportAdaptiveFlywheelPackage(this.path, {super.trace});

  final String path;
}

final class SelectAdaptiveFlywheelDefinition extends AgentsIntent {
  const SelectAdaptiveFlywheelDefinition(this.revision, {super.trace});

  final String revision;
}

final class SaveAdaptiveFlywheelActorBindings extends AgentsIntent {
  SaveAdaptiveFlywheelActorBindings({
    required Iterable<AdaptiveFlywheelAssignmentIntent> assignments,
    super.trace,
  }) : assignments = List<AdaptiveFlywheelAssignmentIntent>.unmodifiable(
         assignments,
       );

  final List<AdaptiveFlywheelAssignmentIntent> assignments;
}

final class SaveAdaptiveFlywheelConfiguration extends AgentsIntent {
  SaveAdaptiveFlywheelConfiguration({
    required Iterable<AdaptiveFlywheelAssignmentIntent> assignments,
    required this.updateAssistant,
    this.assistantAgentId = '',
    this.assistantModelId = '',
    this.assistantReasoningEffort = '',
    super.trace,
  }) : assignments = List<AdaptiveFlywheelAssignmentIntent>.unmodifiable(
         assignments,
       );

  final List<AdaptiveFlywheelAssignmentIntent> assignments;
  final bool updateAssistant;
  final String assistantAgentId;
  final String assistantModelId;
  final String assistantReasoningEffort;
}

final class AdaptiveFlywheelAssignmentIntent {
  const AdaptiveFlywheelAssignmentIntent({
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

final class RefreshAdaptiveFlywheelModelCatalogs extends AgentsIntent {
  RefreshAdaptiveFlywheelModelCatalogs({
    required Iterable<String> agentIds,
    super.trace,
  }) : agentIds = List<String>.unmodifiable(agentIds);

  final List<String> agentIds;
}

final class ReadAdaptiveFlywheelAssistantProfile extends AgentsIntent {
  const ReadAdaptiveFlywheelAssistantProfile({super.trace});
}

final class UpdateAdaptiveFlywheelAssistantProfile extends AgentsIntent {
  const UpdateAdaptiveFlywheelAssistantProfile({
    required this.agentId,
    required this.modelId,
    required this.reasoningEffort,
    super.trace,
  });

  final String agentId;
  final String modelId;
  final String reasoningEffort;
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

final class ShowAgentsWelcome extends AgentsIntent {
  const ShowAgentsWelcome({super.trace});
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
