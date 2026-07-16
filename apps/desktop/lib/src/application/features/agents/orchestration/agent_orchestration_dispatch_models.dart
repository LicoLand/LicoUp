import 'package:flutter_client/src/contracts/agent_dispatch_lane.dart';
import 'package:flutter_client/src/contracts/routing/routing_dispatch_plan.dart';

final class OrchestrationDispatchOutcome {
  const OrchestrationDispatchOutcome({
    required this.route,
    required this.ok,
    required this.status,
    this.replyText = '',
  });

  final RoutingDispatchRoute route;
  final bool ok;
  final String status;
  final String replyText;
}

final class OrchestrationRouteResult {
  const OrchestrationRouteResult({required this.turn, required this.replyText});

  final AgentDispatchTurnResult turn;
  final String replyText;
}
