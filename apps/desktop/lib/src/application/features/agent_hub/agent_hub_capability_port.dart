import 'package:licoup/src/contracts/agent_hub.dart';

/// Declares ordinary Hub lifecycle actions on every client runtime.
final class StaticAgentHubCapabilityPort implements AgentHubCapabilityPort {
  const StaticAgentHubCapabilityPort();

  @override
  bool supports({
    required AgentHubRuntimePlatform platform,
    required AgentHubLifecycleAction action,
  }) {
    return true;
  }
}
