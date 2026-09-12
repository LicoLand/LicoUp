import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/conversations/client_conversation_controller.dart';
import 'package:licoup/src/composition/features/conversation/conversation_feature_composition.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/binding/projection_builder.dart';
import 'package:licoup/src/frontend/features/agents/ui/conversation/canonical_group_conversation_pane.dart';
import 'package:licoup/src/frontend/features/continuous_assistant/continuous_assistant.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_agents_strategy.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/shared/layout_palette_projection.dart';
import 'package:licoup/src/frontend/shared/ui/lico_toast.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/agents/agents_binding.dart';
import 'package:licoup/src/presentation/agents/agents_effect.dart';
import 'package:licoup/src/presentation/agents/agents_intent.dart';
import 'package:licoup/src/presentation/agents/agents_projection.dart';
import 'package:licoup/src/presentation/chrome/chrome_projection.dart';
import 'package:licoup/src/presentation/conversation/conversation_binding.dart';
import 'package:licoup/src/presentation/conversation/conversation_intent.dart';
import 'package:licoup/src/presentation/conversation/conversation_projection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/projections/chrome/chrome_projection_producer.dart';

import '../../fixtures/client_controller/support/fake_agent_service.dart';
import 'journey_bridge.dart';
import 'journey_oracle.dart';

final class JourneySession {
  JourneySession({JourneyBridge? bridge}) : bridge = bridge ?? JourneyBridge();

  final JourneyBridge bridge;
  late final ClientController controller;
  late final ConversationFeatureComposition conversation;
  late final ChromeProjectionProducer chrome;
  late final ValueNotifier<LicoToastNoticesSnapshot> notices;
  StreamSubscription<ProjectionUpdate<ChromeProjection>>? _chromeSub;

  ClientConversationController get owner =>
      controller.clientConversationController;

  Future<void> start() async {
    controller = ClientController(
      agentService: FakeAgentService(),
      conversationNativePort: bridge,
      pendingNoticePollInterval: const Duration(hours: 1),
    );
    conversation = ConversationFeatureComposition(controller);
    chrome = ChromeProjectionProducer(controller);
    notices = ValueNotifier(_chromeNotices(chrome.current));
    _chromeSub = chrome.changes.listen((update) {
      notices.value = _chromeNotices(update.value);
    });
    addTearDown(controller.close);
    addTearDown(conversation.close);
    addTearDown(chrome.close);
    addTearDown(notices.dispose);
    addTearDown(() async {
      await _chromeSub?.cancel();
    });
    await controller.clientConversationController.initialize();
  }

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(1100, 800),
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      JourneyHost(
        size: size,
        notices: notices,
        conversation: conversation.binding,
        agents: journeyAgentsBinding(),
        onActivate: (notice) {
          final id = notice.completionTarget?.notificationId ?? '';
          if (id.isEmpty) return;
          conversation.binding.intents.send(
            ActivateContinuityCompletionNotice(notificationId: id),
          );
        },
        onCreate: () {
          JourneyOracle.sidebarCreateTaps += 1;
        },
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> select(String conversationId) async {
    await controller.clientConversationController.selectConversation(
      conversationId,
    );
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  Future<void> deliverPendingNotices(WidgetTester tester) async {
    await tester.runAsync(owner.pollPendingCompletionNotices);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
  }

  Future<void> close(WidgetTester tester) async {
    final scrollable = messageScrollable();
    if (scrollable.evaluate().isNotEmpty) {
      final position = tester.state<ScrollableState>(scrollable).position;
      position.jumpTo(position.minScrollExtent);
      await tester.pump();
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(controller.close);
  }
}

LicoToastNoticesSnapshot _chromeNotices(ChromeProjection projection) {
  return LicoToastNoticesSnapshot(
    operationNotices: projection.operationNotifications,
    operationRevision: projection.operationAutoRevealRevision,
  );
}

AgentsBinding journeyAgentsBinding() {
  TargetCandidate target(String id, String label) {
    return TargetCandidate(
      id: id,
      target: id,
      label: label,
      kind: 'cli',
      status: 'detected',
      configured: true,
      confidence: 1,
      adapterStatus: 'implemented',
    );
  }

  final targets = <TargetCandidate>[
    target('codex', 'Assistant'),
    target('worker', 'Worker'),
    target('reviewer', 'Reviewer'),
  ];
  return AgentsBinding(
    projection: _StaticProjection(
      AgentsProjection(
        targets: <AgentTargetProjection>[
          for (final item in targets)
            AgentTargetProjection(
              id: item.id,
              displayName: item.label,
              available: true,
              pinned: false,
              capabilityLabel: 'detected',
            ),
        ],
        targetDetails: targets,
        selectedAgentId: 'codex',
        workingDirectoryLabel: '',
        phase: PresentationPhase.ready,
      ),
    ),
    intents: _IntentSink<AgentsIntent>((_) {}),
    effects: const _EmptyEffects<AgentsEffect>(),
  );
}

final class JourneyHost extends StatelessWidget {
  const JourneyHost({
    super.key,
    required this.size,
    required this.notices,
    required this.conversation,
    required this.agents,
    required this.onActivate,
    required this.onCreate,
  });

  final Size size;
  final ValueNotifier<LicoToastNoticesSnapshot> notices;
  final ConversationBinding conversation;
  final AgentsBinding agents;
  final ValueChanged<ChromeOperationNotificationProjection> onActivate;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    return MediaQuery(
      data: MediaQueryData(size: size, disableAnimations: true),
      child: MaterialApp(
        locale: const Locale('en'),
        supportedLocales: LicoStrings.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        theme: buildLicoTheme(
          platformBrightness: Brightness.dark,
        ).copyWith(platform: TargetPlatform.macOS),
        home: Builder(
          builder: (context) => LayoutPaletteScope(
            palette: layoutPaletteFromColors(context.licoColors),
            child: LayoutAgentsStrategyScope(
              strategy: const AgentsPresentationStrategy.messaging(),
              child: LicoToastHost(
                child: LicoToastNoticesListener(
                  notices: notices,
                  onActivate: onActivate,
                  child: Scaffold(
                    body:
                        ProjectionBuilder<
                          CanonicalConversationProjection,
                          CanonicalConversationProjection
                        >(
                          source: conversation.canonicalEvents,
                          select: (projection) => projection,
                          builder: (context, canonical) {
                            return Column(
                              children: [
                                CanonicalGroupConversationSidebar(
                                  conversations: canonical.groupConversations,
                                  selectedConversationId:
                                      canonical.conversationId,
                                  highlightedChildConversationId:
                                      canonical.conversationId,
                                  onSelect: (id) => conversation.intents.send(
                                    SelectCanonicalConversation(id),
                                  ),
                                  onCreate: onCreate,
                                ),
                                Expanded(
                                  child: CanonicalGroupConversationPane(
                                    conversation: conversation,
                                    agents: agents,
                                    canonical: canonical,
                                    turns: conversation.persistentTurns.current,
                                    composer: conversation.composer.current,
                                    attachments:
                                        conversation.attachments.current,
                                    framed: false,
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _StaticProjection<T> implements ProjectionSource<T> {
  const _StaticProjection(this.current);

  @override
  final T current;

  @override
  Stream<ProjectionUpdate<T>> get changes => const Stream.empty();
}

final class _IntentSink<T> implements IntentSink<T> {
  const _IntentSink(this._send);

  final void Function(T intent) _send;

  @override
  void send(T intent) => _send(intent);
}

final class _EmptyEffects<T> implements EffectSource<T> {
  const _EmptyEffects();

  @override
  Stream<T> get effects => const Stream.empty();
}

Finder composerField() =>
    find.byKey(const Key('agent-conversation-composer-input'));

Finder displayedPane() => find.byType(CanonicalGroupConversationPane);

CanonicalGroupConversationPane paneOf(WidgetTester tester) {
  return tester.widget<CanonicalGroupConversationPane>(displayedPane());
}

Future<void> pumpFrames(WidgetTester tester, [int count = 3]) async {
  for (var index = 0; index < count; index += 1) {
    await tester.pump();
  }
}

Finder messageListView() {
  return find.descendant(
    of: find.byKey(const Key('canonical-group-conversation-pane')),
    matching: find.byType(ListView),
  );
}

Finder messageScrollable() {
  return find.descendant(
    of: messageListView(),
    matching: find.byType(Scrollable),
  );
}

Finder sidebarText(String label) {
  return find.descendant(
    of: find.byType(CanonicalGroupConversationSidebar),
    matching: find.text(label),
  );
}

bool _finderOnScreen(WidgetTester tester, Finder finder, Finder viewport) {
  if (finder.evaluate().isEmpty || viewport.evaluate().isEmpty) {
    return false;
  }
  final item = tester.getRect(finder);
  final view = tester.getRect(viewport);
  const headerInset = 96.0;
  const composerInset = 88.0;
  final safe = Rect.fromLTRB(
    view.left,
    view.top + headerInset,
    view.right - 72,
    view.bottom - composerInset,
  );
  return item.overlaps(safe);
}

Future<void> reveal(WidgetTester tester, Finder finder) async {
  final scrollableFinder = messageScrollable();
  if (scrollableFinder.evaluate().isEmpty) {
    return;
  }
  final state = tester.state<ScrollableState>(scrollableFinder);
  Future<void> step(double delta) async {
    final position = state.position;
    final next = (position.pixels + delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (next == position.pixels) {
      return;
    }
    position.jumpTo(next);
    await tester.pump();
  }

  for (var attempt = 0; attempt < 24; attempt += 1) {
    if (_finderOnScreen(tester, finder, scrollableFinder)) {
      return;
    }
    await step(180);
  }
  for (var attempt = 0; attempt < 24; attempt += 1) {
    if (_finderOnScreen(tester, finder, scrollableFinder)) {
      return;
    }
    await step(-180);
  }
}

Future<void> revealCard(WidgetTester tester, String goalId) async {
  await reveal(tester, find.byKey(ContinuousAssistantKeys.card(goalId)));
}

Future<void> expandCard(WidgetTester tester, String goalId) async {
  await revealCard(tester, goalId);
  await tapKey(tester, ContinuousAssistantKeys.expand(goalId));
}

Future<void> tapKey(WidgetTester tester, Key key) async {
  final finder = find.byKey(key);
  await reveal(tester, finder);
  final target = tester.getTopLeft(finder) + const Offset(18, 12);
  await tester.tapAt(target);
  await tester.pump();
}

Future<void> tapOpenCard(WidgetTester tester, String goalId) async {
  await tapKey(tester, ContinuousAssistantKeys.openCard(goalId));
}

Future<void> waitUntil(
  WidgetTester tester,
  bool Function() ready, {
  int maxPumps = 24,
  String because = 'condition was not observed',
}) async {
  for (var attempt = 0; attempt < maxPumps; attempt += 1) {
    if (ready()) {
      return;
    }
    await tester.pump();
  }
  fail(because);
}

Future<void> submitComposer(
  WidgetTester tester,
  JourneySession session,
  String text,
) async {
  final before = JourneyOracle.postedMessageCount(session.bridge);
  final composer = composerField();
  await tester.tap(composer);
  await tester.enterText(composer, text);
  await tester.pump();
  final send = find.byKey(const Key('agent-conversation-composer-send'));
  expect(send, findsOneWidget);
  await tester.tap(send);
  await tester.pump();
  await waitUntil(
    tester,
    () => JourneyOracle.postedMessageCount(session.bridge) > before,
    because: 'composer send did not dispatch conversation.message.post',
  );
  await session.settle(tester);
}

Finder retryAction(String eventId) {
  return find.byKey(Key('messaging-message-retry-action-$eventId'));
}

Finder commandButton(Key key) {
  return find.descendant(
    of: find.byKey(key),
    matching: find.byType(TextButton),
  );
}

bool commandButtonFocused(WidgetTester tester, Key key) {
  final finder = commandButton(key);
  if (finder.evaluate().isEmpty) {
    return false;
  }
  return tester.widget<TextButton>(finder).focusNode?.hasFocus ?? false;
}

Future<void> traverseToCommand(
  WidgetTester tester,
  Key key, {
  int maxHops = 32,
}) async {
  final target = commandButton(key);
  expect(target, findsOneWidget);
  if (commandButtonFocused(tester, key)) {
    return;
  }
  for (var hop = 0; hop < maxHops; hop += 1) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    if (commandButtonFocused(tester, key)) {
      return;
    }
  }
  for (var hop = 0; hop < maxHops; hop += 1) {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
    await tester.pump();
    if (commandButtonFocused(tester, key)) {
      return;
    }
  }
  fail('keyboard traversal did not reach ${key.toString()}');
}
