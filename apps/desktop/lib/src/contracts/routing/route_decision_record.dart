import 'package:flutter/foundation.dart';

@immutable
class RouteDecisionRecord {
  const RouteDecisionRecord({
    required this.chosenAgentId,
    required this.chosenAgentLabel,
    required this.policyId,
    required this.policyVersion,
    required this.alternatives,
    required this.excluded,
    required this.timestamp,
  });

  final String chosenAgentId;
  final String chosenAgentLabel;
  final String policyId;
  final int policyVersion;
  final List<RouteCandidate> alternatives;
  final List<RouteExclusion> excluded;
  final String timestamp;
}

@immutable
class RouteCandidate {
  const RouteCandidate({
    required this.agentId,
    required this.agentLabel,
    required this.priority,
    required this.matchedRoles,
    required this.satisfiedCapabilities,
    required this.allowanceHeadroom,
    required this.reason,
  });

  final String agentId;
  final String agentLabel;
  final int priority;
  final List<String> matchedRoles;
  final List<String> satisfiedCapabilities;
  final int allowanceHeadroom;
  final String reason;
}

@immutable
class RouteExclusion {
  const RouteExclusion({
    required this.agentId,
    required this.agentLabel,
    required this.reason,
    this.detail = '',
  });

  final String agentId;
  final String agentLabel;
  final String reason;
  final String detail;
}
