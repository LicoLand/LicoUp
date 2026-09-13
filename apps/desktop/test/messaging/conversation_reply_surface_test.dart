import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';
import '../support/bundled_font_loader.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_state_holder.dart';
import 'package:licoup/src/contracts/generated/conversation_protocol.g.dart';

import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/contracts/conversation_execution.dart' as execution;
import 'package:licoup/src/contracts/conversation_execution_port.dart' as ports;
import 'package:licoup/src/presentation/conversation/conversation_intent.dart';
import 'package:licoup/src/projections/conversation/conversation_execution_projection_producer.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_pane.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_composer.dart';
import 'package:licoup/src/frontend/shared/messaging/conversation_motion_surface.dart';
import 'package:licoup/src/frontend/shared/messaging/external_conversation_composer.dart';
import 'package:licoup/src/frontend/features/agents/ui/conversation_execution_binding_viewer.dart';
import 'package:licoup/src/frontend/features/agents/ui/execution_process/conversation_execution_viewer.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_agent_avatar.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_message_group.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_agents_strategy.dart';
import 'package:licoup/src/frontend/shared/messaging/conversation_motion/conversation_particle_field.dart';
import 'package:licoup/src/frontend/shared/messaging/conversation_motion/steel_ball_waiting_indicator.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

final _target = TargetCandidate(
  target: 'codex',
  label: 'Codex',
  kind: 'synthetic',
  status: 'detected',
  configured: true,
  confidence: 1,
  adapterStatus: 'implemented',
);
const _reference = execution.ConversationExecutionReference(
  conversationId: 'conversation:synthetic',
  membershipId: 'membership:codex',
  turnHandle: 'dispatch:synthetic',
);
const _user = AgentConversationMessage(
  id: 'synthetic-user',
  role: 'user',
  text: 'Explain the synthetic example.',
  createdAt: '2026-09-13T10:00:00Z',
  stableIdentity: 'synthetic-user',
);

AgentConversationMessage _reply({String text = '', bool waiting = false}) =>
    AgentConversationMessage(
      id: 'dispatch:synthetic-assistant',
      role: 'assistant',
      text: text,
      createdAt: '2026-09-13T10:00:00Z',
      stableIdentity: 'dispatch:synthetic-assistant',
      participantAgentId: 'codex',
      participantLabel: 'Codex',
      executionReference: _reference,
      waitingForReply: waiting,
    );

AgentConversationPaneState _state({
  bool canonical = false,
  bool empty = false,
  bool active = false,
  List<AgentConversationMessage> history = const [],
  List<AgentConversationMessage> replies = const [],
  String id = 'session:synthetic',
}) => AgentConversationPaneState(
  target: _target,
  session: empty && !canonical
      ? null
      : AgentConversationSession(
          id: id,
          agentId: 'codex',
          title: 'Synthetic conversation',
          createdAt: '2026-09-13T10:00:00Z',
          updatedAt: '2026-09-13T10:00:00Z',
          messages: canonical && !empty ? [_user, ...history] : history,
        ),
  liveMessages: empty ? const [] : [if (!canonical) _user, ...replies],
  recentSessions: const [],
  loading: false,
  turnActive: active,
  preparingNewConversation: empty && !canonical,
  composerEnabled: true,
  sendGateReasonCode: '',
  composerDraft: '',
  conversationLabel: 'Synthetic conversation',
  modelOptions: const [],
  selectedModel: '',
  defaultModel: '',
  reasoningEffortOptions: const [],
  selectedReasoningEffort: '',
);

void main() {
  setUpAll(loadBundledVisualFonts);
  for (final canonical in [false, true]) {
    final lane = canonical ? 'canonical' : 'native';
    testWidgets(
      '$lane first send waits in the reply slot and shows early text without waiting for particles',
      (tester) async {
        final state = ValueNotifier(_state(canonical: canonical, empty: true));
        addTearDown(state.dispose);
        await _pumpPane(
          tester,
          state,
          onSend: (text) async {
            state.value = _state(
              canonical: canonical,
              active: true,
              replies: [_reply(waiting: true)],
            );
            return true;
          },
        );
        expect(find.byType(ConversationParticleField), findsOneWidget);
        await _capture(tester, '$lane-dark-sphere');
        await tester.enterText(find.byType(TextField).first, _user.text);
        await tester.pump();
        await tester.tap(
          find.byKey(const Key('agent-conversation-composer-send')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        expect(find.byType(SteelBallWaitingIndicator), findsOneWidget);
        expect(find.byType(MessagingAgentAvatar), findsWidgets);
        final avatar = tester.element(find.byType(MessagingMessageGroup).last);
        await _readyAnchors(tester);
        await _capture(tester, '$lane-dark-waiting');
        state.value = _state(
          canonical: canonical,
          active: true,
          replies: [
            const AgentConversationMessage(
              id: 'tool',
              role: 'tool-call',
              text: 'Hidden tool arguments',
              createdAt: '',
              cardType: 'tool-call',
            ),
            _reply(
              text: 'The first streamed sentence is available immediately.',
            ),
          ],
        );
        await tester.pump();
        expect(find.byType(SteelBallWaitingIndicator), findsNothing);
        expect(
          find.textContaining('first streamed sentence', findRichText: true),
          findsOneWidget,
        );
        expect(
          find.textContaining('Hidden tool arguments', findRichText: true),
          findsNothing,
        );
        expect(
          tester.element(find.byType(MessagingMessageGroup).last),
          same(avatar),
        );
        await tester.pump(const Duration(milliseconds: 650));
        await _capture(tester, '$lane-dark-wave');
        await tester.pump(const Duration(milliseconds: 1000));
        await _capture(tester, '$lane-dark-converging');
        await tester.pump(const Duration(milliseconds: 250));
        await _capture(tester, '$lane-dark-landing');
        await tester.pump(const Duration(milliseconds: 250));
        await tester.pump();
        for (var frame = 0; frame < 3; frame++) {
          await tester.pump();
        }
        await _capture(tester, '$lane-dark-assembled');
        expect(find.byType(ConversationParticleField), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'light external composer uses actual clipped content and dock geometry',
    (tester) async {
      final state = ValueNotifier(_state(canonical: true, empty: true));
      addTearDown(state.dispose);
      await _pumpPane(
        tester,
        state,
        external: true,
        brightness: Brightness.light,
        onSend: (_) async {
          state.value = _state(
            canonical: true,
            active: true,
            replies: [_reply(waiting: true)],
          );
          return true;
        },
      );
      expect(
        Theme.of(
          tester.element(find.byType(AgentConversationActivePane)),
        ).brightness,
        Brightness.light,
      );
      expect(find.text('No messages yet'), findsNothing);
      await _capture(tester, 'external-light-sphere');
      final composer = find.byKey(const Key('synthetic-external-composer'));
      await tester.enterText(
        find.descendant(of: composer, matching: find.byType(TextField)),
        _user.text,
      );
      await tester.pump();
      await tester.tap(
        find.descendant(
          of: composer,
          matching: find.byKey(const Key('agent-conversation-composer-send')),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(find.byType(SteelBallWaitingIndicator), findsOneWidget);
      await _readyAnchors(tester);
      final field = tester.widget<ConversationParticleField>(
        find.byType(ConversationParticleField),
      );
      final hostRect = tester.getRect(
        find.byType(ConversationMotionHost).first,
      );
      final composerRect = tester.getRect(composer).shift(-hostRect.topLeft);
      expect(
        composerRect.contains(field.anchors.composer!.outerRect.center),
        isTrue,
      );
      state.value = _state(
        canonical: true,
        active: true,
        replies: [
          _reply(text: 'The external composer also sends immediately.'),
        ],
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1900));
      await _capture(tester, 'external-light-landing');
      await tester.pump(const Duration(milliseconds: 250));
      for (var frame = 0; frame < 4; frame++) {
        await tester.pump();
      }
      await _capture(tester, 'external-light-assembled');
      expect(find.byType(ConversationParticleField), findsNothing);
      expect(
        find.textContaining('external composer also sends', findRichText: true),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'switching to stored history never plays the first-send transition',
    (tester) async {
      final state = ValueNotifier(_state(empty: true));
      addTearDown(state.dispose);
      await _pumpPane(tester, state);
      state.value = _state(
        id: 'session:other',
        replies: [_reply(text: 'Stored reply')],
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(ConversationParticleField), findsNothing);
      expect(find.text('Stored reply', findRichText: true), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'new canonical membership notice does not disarm the empty conversation sphere',
    (tester) async {
      final state = ValueNotifier(
        _state(
          canonical: true,
          empty: true,
          history: const [
            AgentConversationMessage(
              id: 'membership',
              role: 'event',
              text: 'Added member: Codex',
              createdAt: '',
              cardType: 'membership-changed',
            ),
          ],
        ),
      );
      addTearDown(state.dispose);
      await _pumpPane(tester, state);
      expect(find.byType(ConversationParticleField), findsOneWidget);
      expect(find.text('Added member: Codex'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'real native terminal projections retain a visible, inspectable reply outcome',
    (tester) async {
      final state = ValueNotifier(_state());
      addTearDown(state.dispose);
      await _pumpPane(tester, state);
      for (final outcome in [
        'completed',
        'failed',
        'cancelled',
        'interrupted',
      ]) {
        final holder = ConversationStateHolder();
        void apply(String kind, Map<String, dynamic> payload) =>
            holder.applyDelta(
              ConversationDeltaEvent({
                'event': kind,
                ..._reference.toJson(),
                'payload': payload,
              }),
              scopeKey: 'synthetic',
              participantAgentId: 'codex',
              participantLabel: 'Codex',
            );
        apply('agent.turn.accepted', {});
        state.value = _state(
          active: true,
          replies: holder.messagesFor('synthetic'),
        );
        await tester.pump();
        expect(find.byType(SteelBallWaitingIndicator), findsOneWidget);
        final waitingId = holder
            .messagesFor('synthetic')
            .singleWhere((message) => message.waitingForReply)
            .id;
        apply(
          outcome == 'completed'
              ? 'dispatch.turn.completed'
              : 'dispatch.turn.failed',
          {
            'turnState': outcome == 'completed' ? 'succeeded' : outcome,
            'terminalTransition': outcome == 'completed'
                ? {'kind': 'lifecycle', 'stage': 'completed'}
                : {'kind': 'failed', 'code': 'synthetic_$outcome'},
          },
        );
        final replies = holder.messagesFor('synthetic');
        expect(
          replies
              .singleWhere((message) => message.replyTerminalState != null)
              .id,
          waitingId,
        );
        state.value = _state(replies: replies);
        await tester.pump();
        expect(find.byType(SteelBallWaitingIndicator), findsNothing);
        expect(
          find.byKey(const Key('conversation-reply-terminal')),
          findsOneWidget,
        );
        expect(
          find.text(switch (outcome) {
            'completed' => 'Completed without a text reply',
            'cancelled' => 'Cancelled',
            'interrupted' => 'Interrupted',
            _ => 'Reply failed',
          }),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('conversation-execution-menu')),
          findsWidgets,
        );
        holder.dispose();
      }
    },
  );

  testWidgets(
    'unbound reply execution remains unavailable without observing another turn',
    (tester) async {
      final reader = _Reader();
      addTearDown(reader.observation.dispose);
      final state = ValueNotifier(
        _state(
          replies: const [
            AgentConversationMessage(
              id: 'old-unbound-reply',
              role: 'assistant',
              text: 'A reply with no recorded execution reference.',
              createdAt: '',
            ),
          ],
        ),
      );
      addTearDown(state.dispose);
      await _pumpPane(tester, state, reader: reader);
      await tester.tap(find.byKey(const Key('conversation-execution-menu')));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.byIcon(Icons.visibility_outlined));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byType(ConversationExecutionViewer), findsOneWidget);
      expect(reader.reference, isNull);
      expect(
        find.text('Execution records are unavailable for this reply'),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 500));
      expect(reader.observation.disposed, isFalse);
    },
  );

  testWidgets(
    'reply menu opens only its exact execution and streams complete raw records',
    (tester) async {
      final reader = _Reader();
      final state = ValueNotifier(
        _state(active: true, replies: [_reply(waiting: true)]),
      );
      addTearDown(state.dispose);
      await _pumpPane(tester, state, reader: reader);
      final returnFocus = tester
          .widget<IconButton>(
            find.byKey(const Key('conversation-execution-menu')),
          )
          .focusNode!;
      returnFocus.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byIcon(Icons.visibility_outlined), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump(const Duration(milliseconds: 250));
      expect(reader.reference, _reference);
      expect(find.byType(ConversationExecutionViewer), findsOneWidget);
      for (var frame = 0; frame < 3; frame++) {
        await tester.pump();
      }
      expect(
        find.textContaining('opaque_unknown', findRichText: true),
        findsWidgets,
      );
      reader.observation.emit();
      for (var frame = 0; frame < 4; frame++) {
        await tester.pump();
      }
      expect(
        find.textContaining('second_raw_record', findRichText: true),
        findsWidgets,
      );
      reader.observation.emit(status: 'completed', available: false);
      for (var frame = 0; frame < 4; frame++) {
        await tester.pump();
      }
      expect(
        find.textContaining(
          'Historical records are incomplete',
          findRichText: true,
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('second_raw_record', findRichText: true),
        findsWidgets,
      );
      reader.observation.emit(status: 'running', available: false);
      for (var frame = 0; frame < 4; frame++) {
        await tester.pump();
      }
      expect(
        find.text('Execution records are unavailable for this reply'),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(find.byType(ConversationExecutionViewer), findsNothing);
      expect(reader.observation.disposed, isTrue);
      expect(returnFocus.hasFocus, isTrue);
      expect(find.byType(SteelBallWaitingIndicator), findsOneWidget);
    },
  );
}

Future<void> _pumpPane(
  WidgetTester tester,
  ValueNotifier<AgentConversationPaneState> state, {
  Future<bool> Function(String)? onSend,
  ports.ConversationExecutionReader? reader,
  Brightness brightness = Brightness.dark,
  bool external = false,
}) async {
  final executionProjection = ConversationExecutionProjectionProducer(reader);
  addTearDown(executionProjection.close);
  final executionIntents = _ExecutionIntents(executionProjection);
  tester.view.physicalSize = const Size(1000, 760);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final theme = buildLicoTheme(
    presetId: brightness == Brightness.light
        ? AppearancePresetIds.licoSodaLight
        : AppearancePresetIds.licoSoda,
    platformBrightness: brightness,
  ).copyWith(platform: TargetPlatform.macOS);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      supportedLocales: LicoStrings.supportedLocales,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      theme: theme,
      home: Scaffold(
        body: RepaintBoundary(
          key: const Key('synthetic-conversation-capture'),
          child: ColoredBox(
            color: theme.scaffoldBackgroundColor,
            child: LayoutAgentsStrategyScope(
              strategy: const AgentsPresentationStrategy.messaging(),
              child: ValueListenableBuilder<AgentConversationPaneState>(
                valueListenable: state,
                builder: (context, value, _) {
                  final pane = AgentConversationActivePane(
                    state: value,
                    framed: false,
                    header: const SizedBox(
                      height: 80,
                      child: Center(child: Text('Synthetic conversation')),
                    ),
                    actions: AgentConversationPaneActions(
                      onModelChanged: (_) {},
                      onReasoningEffortChanged: (_) {},
                      onDraftChanged: (_) {},
                      onSend: onSend ?? (_) async => true,
                      onSelectSession: (_) {},
                      onCopyText: (_) async {},
                      onOpenExecution: (context, message, target, focus) =>
                          unawaited(
                            showBoundConversationExecution(
                              context: context,
                              message: message,
                              target: target,
                              conversationTitle: 'Synthetic conversation',
                              projection: executionProjection,
                              intents: executionIntents,
                              onCopyText: (_) async {},
                              returnFocusNode: focus,
                            ),
                          ),
                    ),
                  );
                  if (!external) return pane;
                  return ConversationMotionHost(
                    child: Column(
                      children: [
                        Expanded(
                          child: LayoutExternalComposerScope(
                            hosted: true,
                            child: ExternalConversationComposerClip(
                              child: pane,
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(110, 8, 110, 18),
                          child: RuntimeMessageComposer(
                            key: const Key('synthetic-external-composer'),
                            targetLabel: 'Synthetic conversation',
                            initialDraft: '',
                            busy: false,
                            enabled: true,
                            activityVisible: value.turnActive,
                            modelOptions: const [],
                            selectedModel: '',
                            reasoningEffortOptions: const [],
                            selectedReasoningEffort: '',
                            onModelChanged: (_) {},
                            onReasoningEffortChanged: (_) {},
                            onDraftChanged: (_) {},
                            onSend: onSend ?? (_) async => true,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump();
}

Future<void> _capture(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('LICO_CAPTURE_CONVERSATION_VISUALS')) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const Key('synthetic-conversation-capture')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final file = File('build/reports/conversation-motion/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
  });
}

final class _ExecutionIntents implements IntentSink<ConversationIntent> {
  const _ExecutionIntents(this.projection);
  final ConversationExecutionProjectionProducer projection;

  @override
  void send(ConversationIntent intent) {
    switch (intent) {
      case OpenConversationExecutionView(:final viewId, :final reference):
        projection.open(viewId, reference);
      case CloseConversationExecutionView(:final viewId):
        projection.dismiss(viewId);
      default:
        break;
    }
  }
}

class _Reader implements ports.ConversationExecutionReader {
  execution.ConversationExecutionReference? reference;
  final observation = _Observation();
  @override
  ports.ConversationExecutionObservation observe(
    execution.ConversationExecutionReference value,
  ) {
    reference = value;
    return observation;
  }
}

class _Observation implements ports.ConversationExecutionObservation {
  final _changes =
      StreamController<execution.ConversationExecutionState>.broadcast(
        sync: true,
      );
  bool disposed = false;
  @override
  execution.ConversationExecutionState get snapshot => _snapshot;
  execution.ConversationExecutionState _snapshot =
      const execution.ConversationExecutionState(
        records: [
          execution.ConversationExecutionRecord(
            id: 'record:1',
            rawText: '{ "opaque_unknown": [1, 2], "spacing": " preserved " }\n',
            kind: 'tool',
            timestamp: '',
            cursor: 1,
          ),
        ],
        loading: false,
        observationAvailable: true,
      );
  @override
  Stream<execution.ConversationExecutionState> get changes => _changes.stream;
  void emit({String status = 'running', bool available = true}) {
    _snapshot = execution.ConversationExecutionState(
      records: [
        snapshot.records.first,
        const execution.ConversationExecutionRecord(
          id: 'record:2',
          rawText: 'second_raw_record\n',
          kind: 'reply',
          timestamp: '',
          cursor: 2,
        ),
      ],
      loading: false,
      observationAvailable: available,
      status: status,
    );
    _changes.add(_snapshot);
  }

  @override
  void reconnect() {}
  @override
  void dispose() {
    disposed = true;
    unawaited(_changes.close());
  }
}

Future<void> _readyAnchors(WidgetTester tester) async {
  for (var attempt = 0; attempt < 12; attempt++) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
    final fields = tester.widgetList<ConversationParticleField>(
      find.byType(ConversationParticleField),
    );
    if (fields.isNotEmpty &&
        fields.single.avatarGlyph != null &&
        fields.single.anchors.avatar != null &&
        fields.single.anchors.composer != null) {
      return;
    }
  }
  final field = tester.widget<ConversationParticleField>(
    find.byType(ConversationParticleField),
  );
  expect(field.assembled, isTrue);
  expect(field.avatarGlyph, isNotNull);
  expect(field.anchors.avatar, isNotNull);
  expect(field.anchors.composer, isNotNull);
}
