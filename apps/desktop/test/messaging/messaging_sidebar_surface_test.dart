import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/features/conversations/client_conversation_controller.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_composer.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_conversation_overlay_glass.dart';
import 'package:licoup/src/display/conversation/canonical_group_conversation_pane.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_agents_strategy.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/shared/ui/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/layout_palette_projection.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/agents/agents_binding.dart';
import 'package:licoup/src/presentation/agents/agents_effect.dart';
import 'package:licoup/src/presentation/agents/agents_intent.dart';
import 'package:licoup/src/presentation/agents/agents_projection.dart';
import 'package:licoup/src/presentation/conversation/conversation_binding.dart';
import 'package:licoup/src/presentation/conversation/conversation_effect.dart';
import 'package:licoup/src/presentation/conversation/conversation_intent.dart';
import 'package:licoup/src/presentation/conversation/conversation_projection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

void main() {
  testWidgets(
    'group roster is a centered capsule controlled by the header button',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 640);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final controller = ClientConversationController(
        runner: _GroupConversationRunner(),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.selectConversation('conversation:group');
      final targets = [
        _target('codex', 'Codex'),
        _target('claude-code', 'Claude Code'),
      ];
      final openedAgents = <String>[];
      final bindings = _GroupBindings(
        controller: controller,
        targets: targets,
        onOpenAgent: openedAgents.add,
      );

      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
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
                child: RepaintBoundary(
                  key: const Key('messaging-group-roster-qa-boundary'),
                  child: Scaffold(
                    body: CanonicalGroupConversationPane(
                      conversation: bindings.conversation,
                      agents: bindings.agents,
                      canonical: bindings.canonical,
                      turns: bindings.turns,
                      composer: bindings.composer,
                      attachments: bindings.attachments,
                      onOpenAgentConversations: openedAgents.add,
                      framed: false,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      final paneFinder = find.byKey(
        const Key('canonical-group-conversation-pane'),
      );
      final headerFinder = find.byType(CanonicalGroupConversationHeader);
      final composerFinder = find.byType(RuntimeMessageComposer);
      final composerFieldFinder = find.byKey(
        const Key('agent-conversation-composer-field'),
      );
      final rosterFinder = find.byKey(const Key('canonical-group-roster'));
      final surfaceFinder = find.byKey(
        const Key('canonical-group-roster-surface'),
      );
      final rosterToggleFinder = find.byKey(
        const Key('canonical-group-roster-toggle'),
      );
      final rosterToggleCapsuleFinder = find.byKey(
        const Key('canonical-group-roster-toggle-capsule'),
      );
      expect(paneFinder, findsOneWidget);
      expect(headerFinder, findsOneWidget);
      expect(composerFinder, findsOneWidget);
      expect(composerFieldFinder, findsOneWidget);
      expect(rosterFinder, findsOneWidget);
      expect(surfaceFinder, findsOneWidget);
      expect(rosterToggleFinder, findsOneWidget);
      expect(rosterToggleCapsuleFinder, findsOneWidget);
      expect(tester.takeException(), isNull);

      final paneRect = tester.getRect(paneFinder);
      final headerRect = tester.getRect(headerFinder);
      final composerRect = tester.getRect(composerFinder);
      final composerFieldRect = tester.getRect(composerFieldFinder);
      final surfaceRect = tester.getRect(surfaceFinder);
      final toggleCapsuleRect = tester.getRect(rosterToggleCapsuleFinder);
      final headerGlass = find.descendant(
        of: headerFinder,
        matching: find.byType(MessagingConversationOverlayGlass),
      );
      expect(headerGlass, findsNWidgets(2));
      final identityCapsuleRect = tester.getRect(headerGlass.first);
      expect(headerRect.left, closeTo(paneRect.left, 0.1));
      expect(headerRect.right, closeTo(paneRect.right, 0.1));
      expect(composerRect.left, closeTo(paneRect.left, 0.1));
      expect(composerRect.right, closeTo(paneRect.right, 0.1));
      expect(composerFieldRect.right, closeTo(paneRect.right - 12, 0.1));
      expect(toggleCapsuleRect.width, closeTo(toggleCapsuleRect.height, 0.1));
      expect(
        toggleCapsuleRect.height,
        closeTo(identityCapsuleRect.height, 0.1),
      );
      // Slim capsule: narrower than the header toggle while sharing its
      // right axis.
      expect(surfaceRect.width, lessThan(toggleCapsuleRect.width));
      expect(surfaceRect.right, closeTo(toggleCapsuleRect.right, 0.1));
      expect(surfaceRect.center.dy, closeTo(paneRect.center.dy, 8));
      expect(surfaceRect.top, greaterThan(headerRect.bottom));
      expect(surfaceRect.bottom, lessThan(composerFieldRect.top));

      expect(
        find.descendant(of: surfaceFinder, matching: find.byType(ClipPath)),
        findsNothing,
      );
      expect(
        find.descendant(
          of: surfaceFinder,
          matching: find.byType(BackdropFilter),
        ),
        findsOneWidget,
      );
      expect(
        tester.widget(find.byKey(const Key('canonical-group-roster-glass'))),
        isA<MessagingConversationOverlayGlass>(),
      );
      final actualRosterScrollbar = tester.widget<Scrollbar>(
        find.byKey(const Key('canonical-group-roster-scrollbar')),
      );
      expect(
        actualRosterScrollbar.thickness,
        MessagingDesktopMetrics.groupRosterScrollbarThickness,
      );
      expect(surfaceRect.width, MessagingDesktopMetrics.groupRosterExtent);
      expect(
        tester
            .widget<MessagingConversationOverlayGlass>(
              rosterToggleCapsuleFinder,
            )
            .borderRadius,
        BorderRadius.circular(999),
      );
      expect(find.byIcon(Icons.keyboard_arrow_up_rounded), findsOneWidget);

      await tester.tap(rosterToggleFinder);
      await tester.pump();
      expect(surfaceFinder, findsOneWidget);
      await tester.pumpAndSettle();
      expect(surfaceFinder, findsNothing);
      expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsOneWidget);

      await tester.tap(rosterToggleFinder);
      await tester.pumpAndSettle();
      expect(surfaceFinder, findsOneWidget);
      expect(find.byIcon(Icons.keyboard_arrow_up_rounded), findsOneWidget);

      // Member names live in tooltips only — the capsule shows bare avatars.
      expect(find.text('Codex'), findsNothing);
      expect(find.text('Claude'), findsNothing);
      expect(find.text('Claude Code'), findsNothing);
      expect(
        tester
            .widgetList<Tooltip>(find.byType(Tooltip))
            .map((tooltip) => tooltip.message),
        containsAll(<String>['Codex', 'Claude Code']),
      );
      expect(
        tester
            .widget<MessagingConversationOverlayGlass>(
              find.byKey(const Key('canonical-group-roster-glass')),
            )
            .borderRadius,
        BorderRadius.circular(999),
      );

      // The relay dot hangs on the avatar's bottom-right edge and overlaps
      // the icon; it never claims a separate slot beside it.
      final codexAgentFinder = find.byKey(
        const Key('canonical-group-roster-agent-codex'),
      );
      final codexDotRect = tester.getRect(
        find.byKey(const Key('canonical-group-roster-relay-dot-codex')),
      );
      final codexWellRect = tester.getRect(
        find.descendant(
          of: codexAgentFinder,
          matching: find.byKey(const Key('messaging-agent-avatar-well')),
        ),
      );
      expect(codexDotRect.overlaps(codexWellRect), isTrue);
      expect(codexDotRect.center.dx, greaterThan(codexWellRect.center.dx));
      expect(codexDotRect.center.dy, greaterThan(codexWellRect.center.dy));
      expect(
        codexDotRect.right,
        lessThanOrEqualTo(tester.getRect(codexAgentFinder).right),
      );

      await tester.tap(codexAgentFinder);
      await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 1));
      expect(controller.draft, '@Codex ');

      controller.updateDraft('');
      await tester.pump();
      await tester.tap(codexAgentFinder);
      await tester.pump(kDoubleTapMinTime);
      await tester.tap(codexAgentFinder);
      await tester.pumpAndSettle();
      expect(controller.draft, isEmpty);
      expect(openedAgents, ['codex']);

      expect(
        find.byKey(const Key('messaging-group-roster-qa-boundary')),
        findsOneWidget,
      );
    },
  );
}

final class _GroupBindings {
  _GroupBindings({
    required ClientConversationController controller,
    required List<TargetCandidate> targets,
    required void Function(String agentId) onOpenAgent,
  }) : canonical = CanonicalConversationProjection(
         conversationId: controller.selectedConversationId,
         events: const <CanonicalConversationEventProjection>[],
         conversation: controller.selectedConversation,
         canonicalEvents: controller.events,
         recentParticipantAgentIds: controller.recentParticipantAgentIds,
         hasEarlier: false,
         phase: PresentationPhase.ready,
       ),
       turns = PersistentTurnProjection(
         conversationId: controller.selectedConversationId,
         memberships: const <MembershipTurnProjection>[],
       ),
       composer = ComposerProjection(
         conversationId: 'group:${controller.selectedConversationId}',
         draft: controller.draft,
         inputEnabled: true,
         sendLabel: 'Send',
       ),
       attachments = ConversationAttachmentsProjection(
         conversationId: 'group:${controller.selectedConversationId}',
         attachments: const <ConversationAttachmentProjection>[],
         acceptsImages: true,
       ) {
    final conversationId = controller.selectedConversationId;
    agents = AgentsBinding(
      projection: _StaticProjection(
        AgentsProjection(
          targets: [
            for (final target in targets)
              AgentTargetProjection(
                id: target.target,
                displayName: target.label,
                available: true,
                pinned: false,
                capabilityLabel: target.status,
              ),
          ],
          targetDetails: targets,
          selectedAgentId: targets.isEmpty ? '' : targets.first.target,
          workingDirectoryLabel: '',
          phase: PresentationPhase.ready,
        ),
      ),
      intents: _IntentSink<AgentsIntent>((intent) {
        if (intent case SelectAgent(:final agentId)) onOpenAgent(agentId);
      }),
      effects: const _EmptyEffects<AgentsEffect>(),
    );
    conversation = ConversationBinding(
      projection: _StaticProjection(
        ConversationProjection(
          authority: ConversationAuthority.canonicalConversation,
          conversationId: conversationId,
          membershipId:
              controller.selectedConversation?.assistantMembershipId ?? '',
        ),
      ),
      nativeCatalog: _StaticProjection(
        NativeConversationCatalogProjection(
          sessions: const <NativeConversationSessionProjection>[],
          hasMore: false,
          phase: PresentationPhase.ready,
        ),
      ),
      canonicalEvents: _StaticProjection(canonical),
      persistentTurns: _StaticProjection(turns),
      composer: _StaticProjection(composer),
      attachments: _StaticProjection(attachments),
      tabActivity: _StaticProjection(
        ConversationTabActivityProjection(
          conversationId: conversationId,
          active: true,
          unreadCount: 0,
          requiresAttention: false,
        ),
      ),
      notifications: _StaticProjection(
        ConversationNotificationsProjection(notices: const []),
      ),
      archive: _StaticProjection(
        ConversationArchiveProjection(
          conversations: const [],
          phase: PresentationPhase.ready,
        ),
      ),
      intents: _IntentSink<ConversationIntent>((intent) {
        if (intent case UpdateConversationDraft(:final draft)) {
          controller.updateDraft(draft);
        }
      }),
      effects: const _EmptyEffects<ConversationEffect>(),
    );
  }

  late final AgentsBinding agents;
  late final ConversationBinding conversation;
  final CanonicalConversationProjection canonical;
  final PersistentTurnProjection turns;
  final ComposerProjection composer;
  final ConversationAttachmentsProjection attachments;
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

TargetCandidate _target(String id, String label) => TargetCandidate(
  id: id,
  target: id,
  label: label,
  kind: 'cli',
  status: 'detected',
  configured: true,
  confidence: 1,
  adapterStatus: 'implemented',
  adapterCapabilities: const {
    'conversationDriver': 'implemented',
    'conversationProtocol': 'fixture',
    'conversationReadiness': 'ready',
  },
  supportedActions: const ['runtime.message.send'],
);

final class _GroupConversationRunner implements AgentCommandRunner {
  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) async {
    final request = Map<String, dynamic>.from(jsonDecode(stdinText) as Map);
    return {
      'ok': true,
      'result': switch (request['action']) {
        'conversation.list' => [_summary],
        'conversation.get' => _conversation,
        'conversation.events.page' => {
          'events': <Map<String, dynamic>>[],
          'nextCursor': null,
          'totalCount': 0,
        },
        _ => <String, dynamic>{},
      },
    };
  }

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) =>
      throw UnimplementedError();

  @override
  Stream<Map<String, dynamic>> streamCliJsonLines(List<String> args) =>
      const Stream.empty();

  @override
  Stream<Map<String, dynamic>> streamCliJsonLinesWithStdin(
    List<String> args,
    String stdinText,
  ) => const Stream.empty();
}

const Map<String, dynamic> _summary = {
  'id': 'conversation:group',
  'title': 'Lico',
  'archived': false,
  'pinned': true,
  'isGroup': true,
  'revision': 2,
  'updatedAtUnixMs': 2,
  'membershipCount': 3,
  'eventCount': 0,
};

const Map<String, dynamic> _conversation = {
  'id': 'conversation:group',
  'title': 'Lico',
  'archived': false,
  'pinned': true,
  'isGroup': true,
  'revision': 2,
  'createdAtUnixMs': 1,
  'updatedAtUnixMs': 2,
  'eventCount': 0,
  'memberships': [
    {
      'id': 'membership:owner',
      'conversationId': 'conversation:group',
      'principal': {
        'id': 'human:local',
        'kind': 'human',
        'displayName': 'Local User',
        'createdAtUnixMs': 1,
      },
      'access': 'owner',
      'status': 'active',
      'joinedAtUnixMs': 1,
    },
    {
      'id': 'membership:codex',
      'conversationId': 'conversation:group',
      'principal': {
        'id': 'agent:codex',
        'kind': 'agent',
        'displayName': 'Codex',
        'agentId': 'codex',
        'createdAtUnixMs': 1,
      },
      'access': 'member',
      'status': 'active',
      'joinedAtUnixMs': 1,
    },
    {
      'id': 'membership:claude',
      'conversationId': 'conversation:group',
      'principal': {
        'id': 'agent:claude-code',
        'kind': 'agent',
        'displayName': 'Claude Code',
        'agentId': 'claude-code',
        'createdAtUnixMs': 1,
      },
      'access': 'member',
      'status': 'active',
      'joinedAtUnixMs': 1,
    },
  ],
};
