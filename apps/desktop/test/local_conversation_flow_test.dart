import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/composition/features/agents/agents_feature_composition.dart';
import 'package:licoup/src/composition/features/conversation/conversation_feature_composition.dart';
import 'package:licoup/src/composition/features/mobile_relay/mobile_relay_feature_composition.dart';
import 'package:licoup/src/contracts/generated/conversation_protocol.g.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_workspace.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_agents_strategy.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';

import 'fixtures/client_controller/support/fake_agent_service.dart';
import 'layout/fixtures/layout_destination_presentation_fixture.dart';

void main() {
  testWidgets(
    'normal workspace streams, continues, stops, sends again and reopens history',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('local-conversation-ui-'),
      ))!;
      final host = _SyntheticHost();
      _Workspace? workspace;
      addTearDown(() async {
        host.finish();
        if (workspace != null) await _close(tester, workspace!);
        await tester.runAsync(() => root.delete(recursive: true));
      });

      Future<void> mount() async {
        workspace = _Workspace(host, root);
        await tester.pumpWidget(workspace!.widget);
        await _pump(tester);
        await tester.tap(find.text('Codex').last);
        await _pump(tester);
      }

      Future<void> send(String text) async {
        await tester.enterText(
          find.byKey(const Key('agent-conversation-composer-field')),
          text,
        );
        await tester.pump();
        await tester.tap(
          find.byKey(const Key('agent-conversation-composer-send')),
        );
        await _pump(tester);
      }

      await mount();
      await tester.tap(find.byKey(const Key('messaging-create-conversation')));
      await _pump(tester);
      await tester.tap(find.text('New Chat').last);
      await _pump(tester);
      await send('First question');
      expect(
        host.requests,
        hasLength(1),
        reason: workspace!.controller.lastError,
      );
      expect(host.requests.first['sessionId'], anyOf(isNull, isEmpty));
      expect(find.textContaining('Reply 1', findRichText: true), findsWidgets);
      expect(workspace!.controller.isSendingConversationMessage, isTrue);
      host.finish();
      await _pump(tester);
      expect(workspace!.controller.isSendingConversationMessage, isFalse);

      await send('Second question');
      expect(host.requests.last['sessionId'], 'session-one');
      expect(find.textContaining('Reply 2', findRichText: true), findsWidgets);
      await tester.tap(
        find.byKey(const Key('agent-conversation-composer-send')),
      );
      await _pump(tester);
      expect(host.runtimeCancelCalls, 1);
      expect(host.lastRuntimeCancelRequest['turnHandle'], 'handle-2');
      expect(workspace!.controller.isSendingConversationMessage, isFalse);

      await send('After stop');
      expect(host.requests.last['sessionId'], 'session-one');
      expect(find.textContaining('Reply 3', findRichText: true), findsWidgets);
      host.finish();
      await _pump(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      await _close(tester, workspace!);
      workspace = null;
      await mount();
      await tester.tap(
        find.byKey(const Key('agents-sidebar-conversation-session-one')),
      );
      await _pump(tester);
      expect(find.textContaining('Reply 3', findRichText: true), findsWidgets);
      final messages =
          workspace!.controller.selectedConversationSession!.messages;
      expect(
        messages.map((message) => message.text),
        containsAll([
          'First question',
          'Reply 1',
          'Second question',
          'Reply 2',
          'After stop',
          'Reply 3',
        ]),
      );
      expect(host.requests, hasLength(3));
      await tester.pumpWidget(const SizedBox.shrink());
      await _close(tester, workspace!);
      workspace = null;
      await _pump(tester);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}

Future<void> _pump(WidgetTester tester) async {
  // Streaming indicators are intentionally active until the synthetic host
  // settles, so a frame budget is more appropriate than pumpAndSettle.
  for (var frame = 0; frame < 15; frame++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 2)),
    );
    await tester.pump(const Duration(milliseconds: 40));
  }
}

Future<void> _close(WidgetTester tester, _Workspace workspace) async {
  var closed = false;
  final closing = workspace.close().whenComplete(() => closed = true);
  // Stream completion runs in the widget test zone while storage flushes use
  // real I/O; keep both progressing until the composition has closed.
  while (!closed) {
    await _pump(tester);
  }
  await closing;
}

final class _Workspace {
  _Workspace(_SyntheticHost host, Directory root) {
    controller = ClientController(
      agentService: host,
      portableData: PortableDataRoot(dataDirectoryOverride: root),
    );
    controller.scannedTargets = [
      TargetCandidate(
        target: 'codex',
        label: 'Codex',
        kind: 'cli',
        status: 'detected',
        configured: true,
        confidence: 1,
        binaryPath: '/synthetic/bin/codex',
        adapterStatus: 'implemented',
        adapterCapabilities: const {
          'conversationDriver': 'implemented',
          'conversationReadiness': 'ready',
        },
      ),
    ];
    agents = AgentsFeatureComposition(controller);
    conversation = ConversationFeatureComposition(controller);
    relay = MobileRelayFeatureComposition(
      relay: controller.mobileRelayController,
      secureMesh: controller.secureMeshController,
      homeLayout: controller.mobileHomeLayoutController,
      readMobileRuntime: () => false,
    );
  }
  late final ClientController controller;
  late final AgentsFeatureComposition agents;
  late final ConversationFeatureComposition conversation;
  late final MobileRelayFeatureComposition relay;

  Widget get widget => ProviderScope(
    overrides: [
      ...agents.providerOverrides,
      ...conversation.providerOverrides,
      ...relay.providerOverrides,
    ],
    child: MaterialApp(
      locale: const Locale('en'),
      supportedLocales: LicoStrings.supportedLocales,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: buildLicoTheme(platformBrightness: Brightness.light),
      home: Scaffold(
        body: FixtureLayoutPresentationScope(
          child: LayoutAgentsStrategyScope(
            strategy: const AgentsPresentationStrategy.messaging(),
            child: AgentConversationWorkspace(
              agents: agents.binding,
              conversation: conversation.binding,
              relay: relay.binding,
              onAddTarget: () {},
            ),
          ),
        ),
      ),
    ),
  );

  Future<void> close() async {
    await agents.close();
    await conversation.close();
    await relay.dispose();
    await controller.close();
  }
}

final class _SyntheticHost extends FakeAgentService {
  final requests = <Map<String, dynamic>>[];
  final messages = <Map<String, dynamic>>[];
  Completer<void>? _terminal;
  bool _cancelled = false;

  void finish() {
    if (_terminal?.isCompleted == false) _terminal!.complete();
  }

  @override
  Future<Map<String, dynamic>> handleFakeConversationCommand(
    ConversationProtocolMethod method,
    Map<String, dynamic> request,
  ) async {
    if (method == ConversationProtocolMethod.agentConversationCancel) {
      runtimeCancelCalls++;
      lastRuntimeCancelRequest = request;
      _cancelled = true;
      finish();
      return {'ok': true, 'status': 'cancel_requested'};
    }
    return super.handleFakeConversationCommand(method, request);
  }

  @override
  Stream<Map<String, dynamic>> streamFakeConversation(
    ConversationProtocolMethod method,
    Map<String, dynamic> request,
  ) async* {
    expect(method, ConversationProtocolMethod.agentConversationSend);
    requests.add(request);
    final turn = requests.length;
    final reply = 'Reply $turn';
    _terminal = Completer<void>();
    _cancelled = false;
    Map<String, dynamic> event(String kind, Map<String, dynamic> payload) => {
      'event': kind,
      'sessionId': 'session-one',
      'turnId': 'turn-$turn',
      'turnHandle': 'handle-$turn',
      'conversationId': 'conversation-one',
      'membershipId': 'member-one',
      'payload': payload,
    };
    yield event('agent.turn.accepted', {
      'status': 'accepted',
      'lifecyclePrefix': ['submitted', 'accepted'],
    });
    yield event('agent.message.chunk', {
      'text': reply,
      'messageUnit': 'answer',
      'lifecyclePrefix': ['submitted', 'accepted', 'processing', 'responding'],
    });
    await _terminal!.future;
    for (final entry in [('user', request['text']), ('assistant', reply)]) {
      messages.add({
        'id': 'message-${messages.length}',
        'role': entry.$1,
        'text': entry.$2,
        'createdAt': '2030-01-01T00:00:00Z',
      });
    }
    conversationSessions = {
      'codex': [
        {
          'id': 'session-one',
          'nativeSessionId': 'session-one',
          'agentId': 'codex',
          'title': 'First question',
          'sourceKind': 'codex-native-history',
          'importMode': 'precise-adapter',
          'sourceTool': 'codex',
          'createdAt': '2030-01-01T00:00:00Z',
          'updatedAt': '2030-01-01T00:00:01Z',
          'messages': List.of(messages),
        },
      ],
    };
    // The native lane projects the settled submitted message before its
    // terminal result, including authoritative composer capabilities.
    yield event('conversation.user.message', {
      'text': request['text'],
      'role': 'user',
      'lifecyclePrefix': ['submitted'],
      'turnState': {
        'state': _cancelled ? 'cancelled' : 'succeeded',
        'inputEnabled': true,
        'cancelEnabled': false,
      },
    });
    yield {
      ...event('done', {}),
      'ok': !_cancelled,
      'nativeSessionId': 'session-one',
      'text': reply,
      'turnStatus': _cancelled ? 'cancelled' : 'completed',
      'terminalTransition': {'kind': _cancelled ? 'cancelled' : 'succeeded'},
    };
  }
}
