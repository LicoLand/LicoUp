import 'package:flutter_client/src/contracts/routing/distillation/distillation_input_window.dart';
import 'package:flutter_client/src/contracts/routing/distillation/distillation_lane_contract.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('request window replacement preserves dispatch context and probes', () {
    var probed = false;
    final now = DateTime.utc(2026, 7, 11);
    final request = DistillationRequest(
      sourceSessionId: 'source',
      sourceAgentId: 'agent',
      targetAgentId: 'target',
      distillerSessionId: 'distiller-session',
      turns: const [
        DistillationConversationTurn(role: 'user', text: 'Goal: route'),
      ],
      isDistillerReady: (_) {
        probed = true;
        return true;
      },
      now: () => now,
    );
    final bounded = request.withTurns(const [
      DistillationConversationTurn(role: 'user', text: 'Goal: bounded'),
    ]);

    expect(bounded.targetAgentId, 'target');
    expect(bounded.distillerSessionId, 'distiller-session');
    expect(bounded.now?.call(), now);
    expect(bounded.isDistillerReady?.call('distiller'), isTrue);
    expect(probed, isTrue);
    expect(bounded.contentClasses.hasObjective, isTrue);
  });

  test('lane callback and response expose one-call token accounting', () async {
    Future<DistillationLaneResponse> send(
      DistillationLaneRequest request,
    ) async {
      expect(request.corrective, isTrue);
      return const DistillationLaneResponse(
        ok: true,
        text: '{}',
        promptTokens: 7,
        completionTokens: 5,
      );
    }

    final response = await send(
      const DistillationLaneRequest(
        agentId: 'agent',
        text: 'correct',
        sessionId: 'session',
        corrective: true,
      ),
    );

    expect(response.totalTokens, 12);
    expect(response.usage.dispatchCallCount, 1);
    expect(response.usage.totalTokens, 12);
  });
}
