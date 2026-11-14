import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/client_conversation_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/conversation_quick_switcher.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_features.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/agents/agents_binding.dart';
import 'package:licoup/src/presentation/agents/agents_effect.dart';
import 'package:licoup/src/presentation/agents/agents_intent.dart';
import 'package:licoup/src/presentation/agents/agents_projection.dart';
import 'package:licoup/src/presentation/conversation/conversation_intent.dart';
import 'package:licoup/src/presentation/conversation/conversation_projection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

import '../support/presentation_binding_fakes.dart';

TargetCandidate _agent(String id, {String status = 'detected'}) =>
    TargetCandidate(
      id: id,
      target: id,
      label: id,
      kind: 'cli',
      status: status,
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

ClientConversationSummary _group(
  String id,
  String title, {
  bool archived = false,
}) => ClientConversationSummary(
  id: id,
  title: title,
  archived: archived,
  group: true,
  revision: 1,
  updatedAtUnixMs: 0,
  membershipCount: 2,
  eventCount: 0,
);

const _apps = [
  LayoutQuickSwitcherApp(
    id: 'app:collaboration',
    label: 'Collaboration',
    icon: Icons.account_tree_outlined,
  ),
  LayoutQuickSwitcherApp(
    id: 'plugin:sketch.board',
    label: 'Sketch Board',
    icon: Icons.extension_outlined,
  ),
];

final class _Harness {
  final RecordingIntentSink<AgentsIntent> agentIntents =
      RecordingIntentSink<AgentsIntent>();
  final RecordingIntentSink<ConversationIntent> conversationIntents =
      RecordingIntentSink<ConversationIntent>();
  final List<String> openedApps = [];

  late final AgentsBinding agents = AgentsBinding(
    projection: StaticProjectionSource(
      AgentsProjection(
        targets: const <AgentTargetProjection>[],
        targetDetails: [
          _agent('codex'),
          _agent('claude-code'),
          // Neither the code editor nor an undetected agent is a
          // conversation contact.
          _agent('code'),
          _agent('gemini', status: 'not-detected'),
        ],
        selectedAgentId: '',
        workingDirectoryLabel: '',
        phase: PresentationPhase.ready,
      ),
    ),
    intents: agentIntents,
    effects: const SilentEffectSource<AgentsEffect>(),
  );

  late final conversation = conversationBindingFake(
    projection: const StaticProjectionSource(
      ConversationProjection(
        authority: ConversationAuthority.canonicalConversation,
        conversationId: '',
        membershipId: '',
      ),
    ),
    canonicalEvents: StaticProjectionSource(
      CanonicalConversationProjection(
        conversationId: '',
        events: const <CanonicalConversationEventProjection>[],
        groupConversations: [
          _group('group-release', 'Release review'),
          _group('group-untitled', '   '),
          _group('group-archived', 'Old planning', archived: true),
        ],
        hasEarlier: false,
        phase: PresentationPhase.ready,
      ),
    ),
    intents: conversationIntents,
  );

  Widget app() => MaterialApp(
    theme: buildLicoTheme(platformBrightness: Brightness.light),
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
            key: const Key('open-quick-switcher'),
            onPressed: () => showConversationQuickSwitcher(
              context,
              agents: agents,
              conversation: conversation,
              apps: _apps,
              onOpenApp: openedApps.add,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
}

Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Finder _row(String key) => find.byKey(ValueKey<String>('quick-switcher-$key'));

void main() {
  late _Harness harness;

  setUp(() => harness = _Harness());

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(harness.app());
    await tester.tap(find.byKey(const Key('open-quick-switcher')));
    await _frames(tester);
    expect(
      find.byKey(const Key('conversation-quick-switcher')),
      findsOneWidget,
    );
  }

  List<String> rowKeys(WidgetTester tester) => [
    for (final element
        in find
            .descendant(
              of: find.byKey(const Key('conversation-quick-switcher-results')),
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget.key is ValueKey<String> &&
                    (widget.key! as ValueKey<String>).value.startsWith(
                      'quick-switcher-',
                    ),
              ),
            )
            .evaluate())
      (element.widget.key! as ValueKey<String>).value.substring(
        'quick-switcher-'.length,
      ),
  ];

  testWidgets('lists group and agent conversations, then apps', (tester) async {
    await open(tester);

    expect(rowKeys(tester), [
      'group:group-release',
      'group:group-untitled',
      'agent:codex',
      'agent:claude-code',
      'app:app:collaboration',
      'app:plugin:sketch.board',
    ]);
    expect(find.text('Conversations'), findsOneWidget);
    expect(find.text('Apps'), findsOneWidget);
    expect(
      find.descendant(
        of: _row('group:group-untitled'),
        matching: find.text('Group'),
      ),
      findsOneWidget,
    );
    expect(find.text('Old planning'), findsNothing);
  });

  testWidgets('the field filters every section', (tester) async {
    await open(tester);

    await tester.enterText(
      find.byKey(const Key('conversation-quick-switcher-field')),
      'SKETCH',
    );
    await tester.pump();
    expect(rowKeys(tester), ['app:plugin:sketch.board']);
    expect(find.text('Conversations'), findsNothing);

    await tester.enterText(
      find.byKey(const Key('conversation-quick-switcher-field')),
      'nothing like this',
    );
    await tester.pump();
    expect(find.text('No matching conversations'), findsOneWidget);
  });

  testWidgets('choosing a group conversation selects it', (tester) async {
    await open(tester);

    await tester.tap(_row('group:group-release'));
    await _frames(tester);

    final intent =
        harness.conversationIntents.sent.single as SelectCanonicalConversation;
    expect(intent.conversationId, 'group-release');
    expect(find.byKey(const Key('conversation-quick-switcher')), findsNothing);
  });

  testWidgets('choosing an agent starts its conversation', (tester) async {
    await open(tester);

    await tester.tap(_row('agent:claude-code'));
    await _frames(tester);

    final intent = harness.agentIntents.sent.single as StartAgentConversation;
    expect(intent.agentId, 'claude-code');
  });

  testWidgets('choosing an app opens it', (tester) async {
    await open(tester);

    await tester.tap(_row('app:plugin:sketch.board'));
    await _frames(tester);

    expect(harness.openedApps, ['plugin:sketch.board']);
    expect(harness.conversationIntents.sent, isEmpty);
    expect(harness.agentIntents.sent, isEmpty);
  });

  testWidgets('arrow keys move the selection and Enter chooses it', (
    tester,
  ) async {
    await open(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _frames(tester);
    expect(harness.openedApps, ['plugin:sketch.board']);

    await tester.tap(find.byKey(const Key('open-quick-switcher')));
    await _frames(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _frames(tester);
    expect(
      (harness.agentIntents.sent.single as StartAgentConversation).agentId,
      'codex',
    );
  });

  testWidgets('typing resets the selection to the first match', (tester) async {
    await open(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.enterText(
      find.byKey(const Key('conversation-quick-switcher-field')),
      'c',
    );
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _frames(tester);

    expect(
      (harness.agentIntents.sent.single as StartAgentConversation).agentId,
      'codex',
    );
  });

  testWidgets('Escape closes without choosing', (tester) async {
    await open(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _frames(tester);

    expect(find.byKey(const Key('conversation-quick-switcher')), findsNothing);
    expect(harness.openedApps, isEmpty);
    expect(harness.conversationIntents.sent, isEmpty);
    expect(harness.agentIntents.sent, isEmpty);
  });
}
