import 'package:flutter/foundation.dart';

@immutable
class RoutingDispatchRoute {
  const RoutingDispatchRoute({
    required this.agentId,
    required this.agentLabel,
    required this.role,
    required this.modelName,
    required this.reasoningEffort,
    required this.priority,
    required this.coordinator,
    required this.reason,
  });

  final String agentId;
  final String agentLabel;
  final String role;
  final String modelName;
  final String reasoningEffort;
  final int priority;
  final bool coordinator;
  final String reason;
}

@immutable
class RoutingDispatchSkip {
  const RoutingDispatchSkip({
    required this.agentId,
    required this.agentLabel,
    required this.reason,
    this.circuitBroken = false,
  });

  final String agentId;
  final String agentLabel;
  final String reason;
  final bool circuitBroken;
}

@immutable
class RoutingDispatchPlan {
  const RoutingDispatchPlan({
    required this.strategy,
    required this.routes,
    required this.skipped,
    required this.primaryAgentId,
  });

  final String strategy;
  final List<RoutingDispatchRoute> routes;
  final List<RoutingDispatchSkip> skipped;
  final String primaryAgentId;

  bool get blocked => routes.isEmpty;
}
