import 'package:presentation_contract/presentation_contract.dart';

sealed class AgentHubIntent {
  const AgentHubIntent({this.trace});

  final TraceContext? trace;
}

final class RefreshAgentHub extends AgentHubIntent {
  const RefreshAgentHub({super.trace});
}

final class PlanAgentHubEntryInstall extends AgentHubIntent {
  const PlanAgentHubEntryInstall(
    this.entryId, {
    this.channelId = '',
    this.version = 'latest',
    super.trace,
  });

  final String entryId;
  final String channelId;
  final String version;
}

final class InstallAgentHubEntry extends AgentHubIntent {
  const InstallAgentHubEntry(
    this.entryId, {
    this.channelId = '',
    this.version = 'latest',
    super.trace,
  });

  final String entryId;
  final String channelId;
  final String version;
}

final class UpdateAgentHubEntry extends AgentHubIntent {
  const UpdateAgentHubEntry(this.entryId, {super.trace});

  final String entryId;
}

final class UninstallAgentHubEntry extends AgentHubIntent {
  const UninstallAgentHubEntry(this.entryId, {super.trace});

  final String entryId;
}

final class VerifyAgentHubEntry extends AgentHubIntent {
  const VerifyAgentHubEntry(this.entryId, {super.trace});

  final String entryId;
}

final class RetryAgentHubEntryAction extends AgentHubIntent {
  const RetryAgentHubEntryAction(this.entryId, {super.trace});

  final String entryId;
}

final class OpenAgentHubHomepage extends AgentHubIntent {
  const OpenAgentHubHomepage(this.entryId, {super.trace});

  final String entryId;
}

final class OpenAgentHubAgent extends AgentHubIntent {
  const OpenAgentHubAgent(this.entryId, {super.trace});

  final String entryId;
}
