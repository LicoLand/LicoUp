import 'package:flutter/foundation.dart';
import 'package:flutter_client/src/contracts/routing/routing_policy_schema.dart';

import 'distillation_input_window.dart';
import 'distillation_result_models.dart';
import 'distillation_source_content_classes.dart';
import 'distillation_usage_audit.dart';

@immutable
class DistillationRequest {
  const DistillationRequest({
    required this.sourceSessionId,
    required this.sourceAgentId,
    required this.turns,
    this.targetAgentId = '',
    this.distillerSessionId = '',
    this.isDistillerReady,
    this.now,
  });

  final String sourceSessionId;
  final String sourceAgentId;
  final List<DistillationConversationTurn> turns;
  final String targetAgentId;
  final String distillerSessionId;
  final bool Function(String agentId)? isDistillerReady;
  final DateTime Function()? now;

  DistillationSourceContentClasses get contentClasses =>
      DistillationSourceContentClasses.detect(turns);

  DistillationRequest withTurns(List<DistillationConversationTurn> value) {
    return DistillationRequest(
      sourceSessionId: sourceSessionId,
      sourceAgentId: sourceAgentId,
      turns: value,
      targetAgentId: targetAgentId,
      distillerSessionId: distillerSessionId,
      isDistillerReady: isDistillerReady,
      now: now,
    );
  }
}

@immutable
class DistillationLaneRequest {
  const DistillationLaneRequest({
    required this.agentId,
    required this.text,
    required this.sessionId,
    this.corrective = false,
  });

  final String agentId;
  final String text;
  final String sessionId;
  final bool corrective;
}

@immutable
class DistillationLaneResponse {
  const DistillationLaneResponse({
    required this.ok,
    this.text = '',
    this.errorMessage = '',
    this.sessionId = '',
    this.promptTokens = 0,
    this.completionTokens = 0,
  });

  final bool ok;
  final String text;
  final String errorMessage;
  final String sessionId;
  final int promptTokens;
  final int completionTokens;

  int get totalTokens => promptTokens + completionTokens;

  DistillationUsage get usage => DistillationUsage(
    dispatchCallCount: 1,
    promptTokens: promptTokens,
    completionTokens: completionTokens,
    totalTokens: totalTokens,
  );
}

typedef DispatchLaneSend =
    Future<DistillationLaneResponse> Function(DistillationLaneRequest request);

abstract class DistillationBroker {
  Future<DistillationResult> distill({
    required DistillationRequest request,
    required RoutingPolicyDocument policy,
    required DispatchLaneSend send,
  });
}
