import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/features/agents/contracts/adaptive_flywheel_gateway.dart';
import 'package:licoup/src/application/features/conversations/client_conversation_controller.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/conversations/canonical_group_conversation_pane.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_agents_strategy.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/shell/layout_palette_projection.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

void main() {
  testWidgets(
    'group strategy picker lists authorized revisions, starts on first send, and X does not cancel',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 640);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final conversationRunner = _GroupConversationRunner();
      final gateway = _StrategyGateway();
      final openedRevisions = <String?>[];
      final controller = ClientConversationController(
        runner: conversationRunner,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.selectConversation('conversation:group');
      final targets = [
        _target('codex', 'Codex'),
        _target('worker-a', 'Worker A'),
        _target('claude-code', 'Claude Code'),
      ];

      await tester.pumpWidget(
        _groupApp(
          CanonicalGroupConversationPane(
            controller: controller,
            targets: targets,
            onCopyText: (_) async {},
            framed: false,
            flywheelGateway: gateway,
            onOpenAdaptiveFlywheel: (revision) async {
              openedRevisions.add(revision);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      final picker = find.byKey(const Key('canonical-group-strategy-picker'));
      expect(picker, findsOneWidget);
      expect(find.text('Optional strategy'), findsOneWidget);
      expect(
        find.byKey(const Key('canonical-group-strategy-entry-capsule')),
        findsNothing,
      );

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(picker));
      await tester.pump();
      expect(
        find.byKey(const Key('canonical-group-strategy-picker-panel')),
        findsOneWidget,
      );
      expect(find.text('Authorized Graph'), findsOneWidget);
      expect(find.text('Pending Graph'), findsNothing);
      expect(find.byIcon(Icons.check_rounded), findsNothing);
      final option = find.byKey(
        const Key('canonical-group-strategy-option-rev-auth'),
      );
      expect(tester.getSize(option).height, 32);
      expect(
        find.byKey(const Key('canonical-group-strategy-edit-rev-auth')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const Key('canonical-group-strategy-edit-rev-auth')),
      );
      await tester.pumpAndSettle();
      expect(openedRevisions, <String?>['rev-auth']);

      await mouse.moveTo(const Offset(1, 1));
      await tester.pump(const Duration(milliseconds: 220));
      await mouse.moveTo(tester.getCenter(picker));
      await tester.pump();

      await tester.tap(
        find.byKey(const Key('canonical-group-strategy-option-rev-auth')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Authorized Graph'), findsWidgets);
      expect(
        find.byKey(const Key('canonical-group-strategy-entry-capsule')),
        findsOneWidget,
      );
      expect(conversationRunner.strategyRevision, 'rev-auth');
      final membershipWritesBeforeRemount = conversationRunner.requests
          .where(
            (request) => request['action'] == 'conversation.membership.add',
          )
          .length;
      final strategyWritesBeforeRemount = conversationRunner.requests
          .where((request) => request['action'] == 'conversation.strategy.set')
          .length;

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.pumpWidget(
        _groupApp(
          CanonicalGroupConversationPane(
            controller: controller,
            targets: targets,
            onCopyText: (_) async {},
            framed: false,
            flywheelGateway: gateway,
            onOpenAdaptiveFlywheel: (revision) async {
              openedRevisions.add(revision);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Authorized Graph'), findsWidgets);
      expect(
        find.byKey(const Key('canonical-group-strategy-entry-capsule')),
        findsOneWidget,
      );
      expect(
        conversationRunner.requests
            .where(
              (request) => request['action'] == 'conversation.membership.add',
            )
            .length,
        membershipWritesBeforeRemount,
      );
      expect(
        conversationRunner.requests
            .where(
              (request) => request['action'] == 'conversation.strategy.set',
            )
            .length,
        strategyWritesBeforeRemount,
      );

      final entry = tester.getRect(
        find.byKey(const Key('canonical-group-strategy-entry')),
      );
      final field = tester.getRect(
        find.byKey(const Key('agent-conversation-composer-field')),
      );
      expect(entry.height, closeTo(field.height, 0.5));
      expect(entry.top, closeTo(field.top, 0.5));
      expect(entry.bottom, closeTo(field.bottom, 0.5));

      await mouse.moveTo(const Offset(1, 1));
      await tester.pump(const Duration(milliseconds: 220));
      await mouse.moveTo(tester.getCenter(picker));
      await tester.pump();
      expect(
        find.byKey(const Key('canonical-group-strategy-option-rev-auth')),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      await mouse.moveTo(const Offset(1, 1));
      await tester.pump(const Duration(milliseconds: 220));

      await tester.tap(picker);
      await tester.pumpAndSettle();
      expect(openedRevisions, ['rev-auth', 'rev-auth']);

      await tester.tap(
        find.byKey(const Key('canonical-group-strategy-entry-open')),
      );
      await tester.pumpAndSettle();
      expect(openedRevisions, ['rev-auth', 'rev-auth', 'rev-auth']);
      expect(
        conversationRunner.requests.where(
          (request) => request['action'] == 'conversation.membership.add',
        ),
        isNotEmpty,
      );
      expect(gateway.actions, isNot(contains('strategy.run.start')));
      expect(gateway.actions, isNot(contains('strategy.run.cancel')));

      await tester.enterText(find.byType(TextField), 'start the graph');
      await tester.pump();
      await tester.tap(
        find.byKey(const Key('agent-conversation-composer-send')),
      );
      await tester.pumpAndSettle();

      expect(gateway.actions, contains('strategy.run.start'));
      expect(gateway.startCount, 1);
      final post = conversationRunner.requests.lastWhere(
        (request) => request['action'] == 'conversation.message.post',
      );
      expect(post['content'], 'start the graph');
      expect(post['mentionedMembershipIds'], isEmpty);

      await tester.tap(
        find.byKey(const Key('canonical-group-strategy-entry-clear')),
      );
      await tester.pumpAndSettle();

      expect(openedRevisions, ['rev-auth', 'rev-auth', 'rev-auth']);
      expect(gateway.actions, isNot(contains('strategy.run.cancel')));
      expect(find.text('Optional strategy'), findsOneWidget);
      expect(
        find.byKey(const Key('canonical-group-strategy-entry-capsule')),
        findsNothing,
      );
      expect(conversationRunner.strategyRevision, isEmpty);
      expect(
        conversationRunner.requests
            .where(
              (request) => request['action'] == 'conversation.strategy.set',
            )
            .length,
        strategyWritesBeforeRemount + 1,
      );

      await tester.enterText(find.byType(TextField), 'ordinary after exit');
      await tester.pump();
      await tester.tap(
        find.byKey(const Key('agent-conversation-composer-send')),
      );
      await tester.pumpAndSettle();
      expect(gateway.startCount, 1);
    },
  );

  testWidgets(
    'persists a selected strategy when navigation disposes the pane immediately',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 640);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final inspectionBarrier = Completer<void>();
      final conversationRunner = _GroupConversationRunner();
      final gateway = _StrategyGateway(inspectionBarrier: inspectionBarrier);
      final controller = ClientConversationController(
        runner: conversationRunner,
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.selectConversation('conversation:group');
      final targets = [
        _target('codex', 'Codex'),
        _target('worker-a', 'Worker A'),
      ];

      Widget groupPane() => _groupApp(
        CanonicalGroupConversationPane(
          controller: controller,
          targets: targets,
          onCopyText: (_) async {},
          framed: false,
          flywheelGateway: gateway,
        ),
      );

      await tester.pumpWidget(groupPane());
      await tester.pumpAndSettle();

      final picker = find.byKey(const Key('canonical-group-strategy-picker'));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(picker));
      await tester.pump();
      await tester.tap(
        find.byKey(const Key('canonical-group-strategy-option-rev-auth')),
      );

      // This models selecting a strategy and immediately leaving the screen,
      // before definition inspection or membership reconciliation completes.
      await tester.pumpWidget(const SizedBox(key: Key('other-interface')));
      await tester.pump();

      expect(conversationRunner.strategyRevision, 'rev-auth');
      expect(
        conversationRunner.requests
            .where(
              (request) => request['action'] == 'conversation.strategy.set',
            )
            .length,
        1,
      );

      inspectionBarrier.complete();
      await tester.pumpAndSettle();
      await tester.pumpWidget(groupPane());
      await tester.pumpAndSettle();

      expect(find.text('Authorized Graph'), findsWidgets);
      expect(
        find.byKey(const Key('canonical-group-strategy-entry-capsule')),
        findsOneWidget,
      );
      expect(conversationRunner.strategyRevision, 'rev-auth');
    },
  );
}

Widget _groupApp(Widget child) {
  return MaterialApp(
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
          child: Scaffold(body: child),
        ),
      ),
    ),
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

final class _StrategyGateway implements AdaptiveFlywheelGateway {
  _StrategyGateway({this.inspectionBarrier});

  final Completer<void>? inspectionBarrier;
  final List<String> actions = [];
  int startCount = 0;

  @override
  Future<Object?> execute(Map<String, dynamic> request) async {
    final action = (request['action'] ?? '').toString();
    actions.add(action);
    if (action == 'strategy.definition.inspect') {
      await inspectionBarrier?.future;
      return {
        'projection': {
          'status': 'pending',
          'currentStates': <String>[],
          'neighborStates': <String>[],
          'allowedOperations': ['strategy.run.start'],
          'bindings': [
            {
              'slotId': 'entry',
              'valueId': 'codex',
              'ordinal': 0,
              'revision': 1,
            },
            {
              'slotId': 'worker-a',
              'valueId': 'worker-a',
              'ordinal': 0,
              'revision': 1,
            },
          ],
        },
        'workflow': {
          'initial': 'work',
          'actorSlots': [
            {
              'id': 'entry',
              'kind': 'actor',
              'label': 'Entry',
              'required': true,
              'entry': true,
            },
            {
              'id': 'worker-a',
              'kind': 'actor',
              'label': 'Worker A',
              'required': true,
            },
          ],
          'states': [
            {'id': 'work', 'kind': 'actor', 'label': 'Work'},
          ],
          'transitions': <Map<String, dynamic>>[],
        },
      };
    }
    return switch (action) {
      'strategy.definition.list' => [
        {
          'definitionId': 'authorized',
          'name': 'Authorized Graph',
          'version': '1.0.0',
          'revisionDigest': 'rev-auth',
          'semanticsDigest': 'sem-auth',
          'authorized': true,
        },
        {
          'definitionId': 'pending',
          'name': 'Pending Graph',
          'version': '1.0.0',
          'revisionDigest': 'rev-pending',
          'semanticsDigest': 'sem-pending',
          'authorized': false,
        },
      ],
      'strategy.run.active' => {'runId': startCount == 0 ? null : 'run-1'},
      'strategy.run.start' => () {
        startCount += 1;
        return {'runId': 'run-1', 'needsHumanInput': false};
      }(),
      _ => throw StateError('unexpected action $action'),
    };
  }
}

final class _GroupConversationRunner implements AgentCommandRunner {
  final List<Map<String, dynamic>> requests = [];
  final Map<String, String> addedAgents = {};
  String strategyRevision = '';
  int revision = 2;

  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) async {
    final request = Map<String, dynamic>.from(jsonDecode(stdinText) as Map);
    requests.add(request);
    final action = request['action'];
    if (action == 'conversation.membership.add') {
      final principal = Map<String, dynamic>.from(request['principal'] as Map);
      addedAgents[(principal['agentId'] ?? '').toString()] =
          (principal['displayName'] ?? '').toString();
    } else if (action == 'conversation.strategy.set') {
      final next = (request['strategyRevision'] ?? '').toString();
      if (next != strategyRevision) {
        strategyRevision = next;
        revision += 1;
      }
    }
    return {
      'ok': true,
      'result': switch (action) {
        'conversation.list' => [_summary(revision)],
        'conversation.get' => _conversation(
          addedAgents,
          strategyRevision: strategyRevision,
          revision: revision,
        ),
        'conversation.events.page' => {
          'events': <Map<String, dynamic>>[],
          'nextCursor': null,
          'totalCount': 0,
        },
        'conversation.message.post' => {
          'event': <String, dynamic>{
            'id': 'event:posted',
            'conversationId': 'conversation:group',
            'sequence': 2,
            'authorMembershipId': 'membership:owner',
            'kind': 'message',
            'createdAtUnixMs': 2,
            'finalized': true,
            'parts': <Map<String, dynamic>>[],
          },
          'directTurns': <Map<String, dynamic>>[],
        },
        'conversation.membership.add' => <String, dynamic>{},
        'conversation.strategy.set' => <String, dynamic>{},
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

Map<String, dynamic> _summary(int revision) => {
  'id': 'conversation:group',
  'title': 'Lico',
  'archived': false,
  'pinned': true,
  'isGroup': true,
  'revision': revision,
  'updatedAtUnixMs': 2,
  'membershipCount': 3,
  'eventCount': 0,
};

Map<String, dynamic> _conversation(
  Map<String, String> addedAgents, {
  required String strategyRevision,
  required int revision,
}) => {
  'id': 'conversation:group',
  'title': 'Lico',
  'archived': false,
  'pinned': true,
  'isGroup': true,
  if (strategyRevision.isNotEmpty) 'strategyRevision': strategyRevision,
  'revision': revision,
  'createdAtUnixMs': 1,
  'updatedAtUnixMs': 2,
  'eventCount': 0,
  'memberships': [
    _membership(
      id: 'membership:owner',
      principalId: 'human:local',
      kind: 'human',
      label: 'Local User',
      access: 'owner',
    ),
    _membership(
      id: 'membership:codex',
      principalId: 'agent:codex',
      kind: 'agent',
      label: 'Codex',
      agentId: 'codex',
    ),
    _membership(
      id: 'membership:claude',
      principalId: 'agent:claude-code',
      kind: 'agent',
      label: 'Claude Code',
      agentId: 'claude-code',
    ),
    for (final entry in addedAgents.entries)
      _membership(
        id: 'membership:${entry.key}',
        principalId: 'agent:${entry.key}',
        kind: 'agent',
        label: entry.value,
        agentId: entry.key,
      ),
  ],
};

Map<String, dynamic> _membership({
  required String id,
  required String principalId,
  required String kind,
  required String label,
  String agentId = '',
  String access = 'member',
}) => {
  'id': id,
  'conversationId': 'conversation:group',
  'principal': {
    'id': principalId,
    'kind': kind,
    'displayName': label,
    if (agentId.isNotEmpty) 'agentId': agentId,
    'createdAtUnixMs': 1,
  },
  'access': access,
  'status': 'active',
  'joinedAtUnixMs': 1,
};
