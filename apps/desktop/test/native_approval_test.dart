import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';
import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/backend/features/agents/services/agent_conversation_service.dart';
import 'package:licoup/src/contracts/agent_conversation_tab_activity.dart';
import 'package:licoup/src/contracts/generated/conversation_protocol.g.dart';
import 'package:licoup/src/frontend/features/agents/ui/native_approval_card.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/platform/native_client/native_cli_ports.dart';
import 'package:licoup/src/presentation/conversation/conversation_intent.dart';
import 'package:licoup/src/presentation/conversation/conversation_projection.dart';

import 'fixtures/client_controller/support/fake_agent_service.dart';
import 'support/fake_conversation_transport.dart';

var _fixtureSeq = 0;

String _synth(String label) => '$label-${_fixtureSeq++}';

final _approvalTokenRef = _synth('token-1');


final _event = AgentDispatchEvent(
  kind: 'agent.approval.needed',
  sessionId: 'session-1',
  turnId: 'turn-1',
  payload: {
    'agentId': 'codex',
    'adapterCallbackTokenRef': _approvalTokenRef,
    'pendingOperationId': 'codex-park-token-1',
    'displaySummary': 'Run npm test',
    'requestedTools': ['shell'],
  },
);

/// A steer RPC executor that answers each call with [reply] or throws the
/// RPC error code [failure].
FakeConversationTransport _rpc({String failure = ''}) =>
    FakeConversationTransport(
      command: (method, params) async {
        if (failure.isNotEmpty) throw LicoClientRpcException(failure);
        return {'ok': true, 'resolved': true};
      },
    );

ClientController _controller(FakeConversationTransport rpc) {
  final controller = ClientController(
    agentService: FakeAgentService(),
    conversationService: AgentConversationService(native: rpc.native),
  );
  addTearDown(controller.dispose);
  return controller;
}

void main() {
  test(
    'allow resolves the parked request through the steer operation',
    () async {
      final rpc = _rpc();
      final controller = _controller(rpc);

      await controller.conversationHandleNativeApprovalNeeded(
        agentId: 'codex',
        event: _event,
      );
      expect(controller.pendingNativeApprovals.single.sessionId, 'session-1');
      expect(
        controller.conversationTabActivityFor('codex'),
        AgentConversationTabActivity.needsApproval,
      );
      expect(controller.statusMessage, contains('Run npm test'));
      expect(controller.statusMessage, isNot(contains('remote')));

      await controller.resolveNativeApproval('codex-park-token-1', allow: true);

      final request = rpc.requests.single;
      expect(request.method, ConversationProtocolMethod.agentConversationSteer);
      expect(request.params, {
        'agent': 'codex',
        'sessionId': 'session-1',
        'turnId': 'turn-1',
        'adapterCallbackTokenRef': _approvalTokenRef,
        'interactionResponse': {'allow': true},
      });
      expect(controller.pendingNativeApprovals, isEmpty);
      expect(controller.nativeApprovalErrorCode, isEmpty);
      expect(
        controller.conversationTabActivityFor('codex'),
        AgentConversationTabActivity.none,
      );
    },
  );

  test('deny sends allow false', () async {
    final rpc = _rpc();
    final controller = _controller(rpc);
    await controller.conversationHandleNativeApprovalNeeded(
      agentId: 'codex',
      event: _event,
    );
    await controller.resolveNativeApproval('codex-park-token-1', allow: false);
    expect(rpc.requests.single.params['interactionResponse'], {'allow': false});
    expect(controller.pendingNativeApprovals, isEmpty);
  });

  for (final settled in [
    'native_interaction_route_consumed',
    'native_interaction_route_missing',
  ]) {
    test('$settled counts as already resolved', () async {
      final controller = _controller(_rpc(failure: settled));
      await controller.conversationHandleNativeApprovalNeeded(
        agentId: 'codex',
        event: _event,
      );
      await controller.resolveNativeApproval('codex-park-token-1', allow: true);
      expect(controller.pendingNativeApprovals, isEmpty);
      expect(controller.nativeApprovalErrorCode, isEmpty);
    });
  }

  test('other failures keep the request and surface their code', () async {
    final controller = _controller(_rpc(failure: 'transport_failed'));
    await controller.conversationHandleNativeApprovalNeeded(
      agentId: 'codex',
      event: _event,
    );
    await controller.resolveNativeApproval('codex-park-token-1', allow: true);
    expect(controller.pendingNativeApprovals, hasLength(1));
    expect(controller.nativeApprovalErrorCode, 'transport_failed');
    expect(controller.resolvingNativeApprovals, isEmpty);
  });

  test('the service refuses an unscoped request before any RPC', () async {
    final rpc = _rpc();
    final service = AgentConversationService(native: rpc.native);
    expect(
      await service.resolveNativeApproval(
        agentId: 'codex',
        sessionId: '',
        turnId: 'turn-1',
        adapterCallbackTokenRef: _approvalTokenRef,
        allow: true,
      ),
      'native_interaction_scope_missing',
    );
    expect(rpc.requests, isEmpty);
  });

  testWidgets('the card sends Allow and Deny decisions', (tester) async {
    final intents = _RecordingIntents();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: LicoStrings.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        theme: buildLicoTheme(platformBrightness: Brightness.light),
        home: Scaffold(
          body: NativeApprovalCard(
            approvals: [
              NativeApprovalRequestProjection(
                pendingOperationId: 'op-1',
                agentId: 'codex',
                summary: 'Run npm test',
                requestedTools: const ['shell'],
              ),
              NativeApprovalRequestProjection(
                pendingOperationId: 'op-2',
                agentId: 'codex',
                summary: 'Write README.md',
                resolving: true,
              ),
            ],
            errorCode: 'transport_failed',
            intents: intents,
          ),
        ),
      ),
    );

    expect(find.text('Waiting for approval'), findsOneWidget);
    expect(find.text('codex · Run npm test'), findsOneWidget);
    expect(find.byKey(const Key('native-approval-error')), findsOneWidget);

    await tester.tap(find.byKey(const Key('native-approval-allow-op-1')));
    await tester.tap(find.byKey(const Key('native-approval-deny-op-1')));
    // A request whose decision is in flight takes no second decision.
    await tester.tap(find.byKey(const Key('native-approval-allow-op-2')));
    expect(
      intents.sent.map((intent) => (intent.pendingOperationId, intent.allow)),
      [('op-1', true), ('op-1', false)],
    );
  });
}

final class _RecordingIntents implements IntentSink<ConversationIntent> {
  final List<ResolveNativeApproval> sent = [];

  @override
  void send(ConversationIntent intent) {
    if (intent is ResolveNativeApproval) sent.add(intent);
  }
}
