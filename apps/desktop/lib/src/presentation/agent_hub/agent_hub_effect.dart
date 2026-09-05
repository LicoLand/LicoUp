import 'package:presentation_contract/presentation_contract.dart';

sealed class AgentHubEffect {
  const AgentHubEffect({this.trace});

  final TraceContext? trace;
}

final class AgentHubInstallPlanReady extends AgentHubEffect {
  const AgentHubInstallPlanReady(
    this.entryId,
    this.summary, {
    this.channelId = '',
    this.version = 'latest',
    super.trace,
  });

  final String entryId;
  final String summary;
  final String channelId;
  final String version;
}

final class AgentHubExternalOpenRequested extends AgentHubEffect {
  const AgentHubExternalOpenRequested(this.entryId, this.uri, {super.trace});

  final String entryId;
  final String uri;
}

final class AgentHubAgentOpenRequested extends AgentHubEffect {
  const AgentHubAgentOpenRequested(this.entryId, {super.trace});

  final String entryId;
}

enum AgentHubOperationEffectKind { install, update, uninstall, verify, rescan }

final class AgentHubOperationCompleted extends AgentHubEffect {
  AgentHubOperationCompleted(
    this.entryId,
    this.kind, {
    Iterable<String> events = const [],
    super.trace,
  }) : events = List.unmodifiable(events);

  final String entryId;
  final AgentHubOperationEffectKind kind;
  final List<String> events;
}

final class AgentHubActionRejected extends AgentHubEffect {
  const AgentHubActionRejected(this.entryId, this.reasonCode, {super.trace});

  final String entryId;
  final String reasonCode;
}
