import 'package:presentation_contract/presentation_contract.dart';

sealed class PluginManagementEffect {
  const PluginManagementEffect({this.trace});

  final TraceContext? trace;
}

enum PluginLifecyclePlanAction { install, uninstall }

final class PluginLifecyclePlanReady extends PluginManagementEffect {
  const PluginLifecyclePlanReady({
    required this.planId,
    required this.agentId,
    required this.pluginId,
    required this.pluginLabel,
    required this.action,
    super.trace,
  });

  final String planId;
  final String agentId;
  final String pluginId;
  final String pluginLabel;
  final PluginLifecyclePlanAction action;
}

final class PluginActionCompleted extends PluginManagementEffect {
  const PluginActionCompleted(this.reasonCode, {super.trace});

  final String reasonCode;
}

final class CollaborationInstallPlanReady extends PluginManagementEffect {
  const CollaborationInstallPlanReady(this.summary, {super.trace});

  final String summary;
}

final class PluginActionRejected extends PluginManagementEffect {
  const PluginActionRejected(this.pluginId, this.reasonCode, {super.trace});

  final String pluginId;
  final String reasonCode;
}
