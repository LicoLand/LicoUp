import 'agent_usage_panel/cache_scenarios.dart';
import 'agent_usage_panel/formatting_scenarios.dart';
import 'agent_usage_panel/model_share_scenarios.dart';
import 'agent_usage_panel/polling_scenarios.dart';
import 'agent_usage_panel/timeline_scenarios.dart';

void registerAgentUsageVisualizationScenarios() {
  registerAgentUsageFormattingScenarios();
  registerAgentUsageTimelineScenarios();
  registerAgentUsageModelShareScenarios();
}

void registerAgentUsageRefreshScenarios() {
  registerAgentUsagePollingScenarios();
  registerAgentUsageCacheScenarios();
}
