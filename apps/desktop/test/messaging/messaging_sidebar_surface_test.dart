import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/features/conversations/client_conversation_controller.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_composer.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_conversation_overlay_glass.dart';
import 'package:licoup/src/frontend/features/conversations/canonical_group_conversation_pane.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_agents_strategy.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shell/layout_palette_projection.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

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
                      controller: controller,
                      targets: targets,
                      onCopyText: (_) async {},
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
      expect(surfaceRect.width, closeTo(toggleCapsuleRect.width, 0.1));
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

      expect(find.text('Codex'), findsOneWidget);
      expect(find.text('Claude'), findsOneWidget);
      expect(find.text('Claude Code'), findsNothing);
      expect(
        tester
            .widgetList<Tooltip>(find.byType(Tooltip))
            .map((tooltip) => tooltip.message),
        containsAll(<String>['Codex', 'Claude Code']),
      );

      final codexAvatar = find.byKey(
        const Key('canonical-group-roster-agent-codex'),
      );
      await tester.tap(codexAvatar);
      await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 1));
      expect(controller.draft, '@Codex ');

      controller.updateDraft('');
      await tester.pump();
      await tester.tap(codexAvatar);
      await tester.pump(kDoubleTapMinTime);
      await tester.tap(codexAvatar);
      await tester.pumpAndSettle();
      expect(controller.draft, isEmpty);
      expect(openedAgents, ['codex']);

      await expectLater(
        find.byKey(const Key('messaging-group-roster-qa-boundary')),
        matchesGoldenFile('../goldens/messaging/sidebar_surface.png'),
      );
    },
  );
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
