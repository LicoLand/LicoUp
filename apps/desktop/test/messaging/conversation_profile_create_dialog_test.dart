import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/conversation/conversation_profile_create_dialog.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/shared/layout_palette_projection.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/agents/agents_intent.dart';
import 'package:licoup/src/presentation/conversation/conversation_effect.dart';
import 'package:licoup/src/presentation/conversation/conversation_intent.dart';

final class _Intents implements IntentSink<ConversationIntent> {
  final List<ConversationIntent> sent = <ConversationIntent>[];

  @override
  void send(ConversationIntent intent) => sent.add(intent);
}

final class _AgentIntents implements IntentSink<AgentsIntent> {
  final List<AgentsIntent> sent = <AgentsIntent>[];

  @override
  void send(AgentsIntent intent) => sent.add(intent);
}

final class _Effects implements EffectSource<ConversationEffect> {
  final StreamController<ConversationEffect> controller =
      StreamController<ConversationEffect>.broadcast();

  @override
  Stream<ConversationEffect> get effects => controller.stream;
}

TargetCandidate _callableTarget(String target, String label) => TargetCandidate(
  target: target,
  label: label,
  kind: 'cli',
  status: 'detected',
  configured: true,
  confidence: 1,
  binaryPath: '/usr/local/bin/$target',
  adapterStatus: 'implemented',
  modelCatalog: const {
    'models': [
      {
        'id': 'model-one',
        'reasoningEfforts': ['low', 'high'],
      },
    ],
  },
  adapterCapabilities: const {
    'conversationDriver': 'supported',
    'conversationCapabilityMatrix': {
      'permissionModes': ['ask', 'auto'],
    },
  },
);

Future<void> _openDialog(
  WidgetTester tester, {
  required _Intents intents,
  required _Effects effects,
  _AgentIntents? agentsIntents,
  List<TargetCandidate> targets = const [],
}) async {
  await tester.pumpWidget(
    MaterialApp(
      supportedLocales: LicoStrings.supportedLocales,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      theme: buildLicoTheme(platformBrightness: Brightness.dark),
      home: Builder(
        builder: (context) => LayoutPaletteScope(
          palette: layoutPaletteFromColors(context.licoColors),
          child: Scaffold(
            body: Center(
              child: TextButton(
                key: const Key('open-profile-dialog'),
                onPressed: () => showConversationProfileCreateDialog(
                  context: context,
                  intents: intents,
                  effects: effects,
                  agentsIntents: agentsIntents ?? _AgentIntents(),
                  targets: targets,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const Key('open-profile-dialog')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders mascot picker, name field, cascade and a collapsed '
      'advanced section', (tester) async {
    final intents = _Intents();
    final effects = _Effects();
    addTearDown(effects.controller.close);
    await _openDialog(
      tester,
      intents: intents,
      effects: effects,
      targets: [_callableTarget('codex', 'Codex')],
    );

    expect(
      find.byKey(const Key('conversation-profile-create-dialog')),
      findsOneWidget,
    );
    expect(find.text('Create Agent'), findsOneWidget);
    expect(find.byKey(const Key('agent-profile-name-field')), findsOneWidget);
    expect(find.text('Avatar'), findsOneWidget);
    expect(
      find.byKey(const Key('agent-profile-advanced-toggle')),
      findsOneWidget,
    );
    // Advanced options stay collapsed until the section opens.
    expect(
      find.byKey(const Key('agent-profile-context-window-field')),
      findsNothing,
    );
    expect(find.text('Advanced'), findsOneWidget);

    final toggle = find.byKey(const Key('agent-profile-advanced-toggle'));
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('agent-profile-context-window-field')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('agent-profile-environment-field')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('agent-profile-instructions-field')),
      findsOneWidget,
    );
    // The permission selector appears only after an Agent with a declared
    // permission control is picked.
    expect(
      find.byKey(const Key('agent-profile-permission-mode')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('create stays disabled until name and agent resolve, then '
      'sends the profile intent', (tester) async {
    final intents = _Intents();
    final effects = _Effects();
    addTearDown(effects.controller.close);
    await _openDialog(
      tester,
      intents: intents,
      effects: effects,
      targets: [_callableTarget('codex', 'Codex')],
    );

    final confirm = find.byKey(const Key('agent-profile-create-confirm'));
    expect(confirm, findsOneWidget);
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);

    await tester.enterText(
      find.byKey(const Key('agent-profile-name-field')),
      'Nova',
    );
    await tester.pump();
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);

    // Pick the backing agent in the cascade, then its model and effort.
    final agentOption = find.byKey(const Key('agent-profile-option-codex'));
    await tester.ensureVisible(agentOption);
    await tester.pumpAndSettle();
    await tester.tap(agentOption);
    await tester.pumpAndSettle();
    final modelOption = find.byKey(
      const Key('agent-profile-model-codex-model-one'),
    );
    await tester.ensureVisible(modelOption);
    await tester.pumpAndSettle();
    await tester.tap(modelOption);
    await tester.pumpAndSettle();
    final effortOption = find.byKey(
      const Key('agent-profile-effort-codex-high'),
    );
    await tester.ensureVisible(effortOption);
    await tester.pumpAndSettle();
    await tester.tap(effortOption);
    await tester.pumpAndSettle();

    expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
    await tester.ensureVisible(confirm);
    await tester.pumpAndSettle();
    await tester.tap(confirm);
    await tester.pump();

    final create = intents.sent.whereType<CreateConversationProfile>();
    expect(create, hasLength(1));
    final profile = create.single.profile;
    expect(profile.name, 'Nova');
    expect(profile.agentId, 'codex');
    expect(profile.modelId, 'model-one');
    expect(profile.reasoningEffort, 'high');
    expect(profile.mascotAvatarId, isNotEmpty);
    expect(profile.principalId, startsWith('profile:'));

    effects.controller.add(
      const ConversationProfileCreated('conversation:direct'),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('conversation-profile-create-dialog')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('advanced fields flow into the intent payload', (tester) async {
    final intents = _Intents();
    final effects = _Effects();
    addTearDown(effects.controller.close);
    await _openDialog(
      tester,
      intents: intents,
      effects: effects,
      targets: [_callableTarget('codex', 'Codex')],
    );

    await tester.enterText(
      find.byKey(const Key('agent-profile-name-field')),
      'Nova',
    );
    final agentOption = find.byKey(const Key('agent-profile-option-codex'));
    await tester.ensureVisible(agentOption);
    await tester.pumpAndSettle();
    await tester.tap(agentOption);
    await tester.pumpAndSettle();
    final modelOption = find.byKey(
      const Key('agent-profile-model-codex-model-one'),
    );
    await tester.ensureVisible(modelOption);
    await tester.pumpAndSettle();
    await tester.tap(modelOption);
    await tester.pumpAndSettle();
    final effortOption = find.byKey(
      const Key('agent-profile-effort-codex-low'),
    );
    await tester.ensureVisible(effortOption);
    await tester.pumpAndSettle();
    await tester.tap(effortOption);
    await tester.pumpAndSettle();

    final toggle = find.byKey(const Key('agent-profile-advanced-toggle'));
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('agent-profile-context-window-field')),
      '64000',
    );
    await tester.enterText(
      find.byKey(const Key('agent-profile-environment-field')),
      '/work',
    );
    await tester.enterText(
      find.byKey(const Key('agent-profile-instructions-field')),
      'Answer briefly.',
    );
    await tester.pump();

    final confirm = find.byKey(const Key('agent-profile-create-confirm'));
    await tester.ensureVisible(confirm);
    await tester.pumpAndSettle();
    await tester.tap(confirm);
    await tester.pump();

    final profile = intents.sent
        .whereType<CreateConversationProfile>()
        .single
        .profile;
    expect(profile.contextWindowTokens, 64000);
    expect(profile.environment, '/work');
    expect(profile.instructions, 'Answer briefly.');
    expect(profile.permissionMode, isNotEmpty);
    final intent = profile.intent;
    expect(intent['preferredModel'], 'model-one');
    expect(intent['preferredReasoningEffort'], 'low');
    expect(intent['preferredContextWindow'], 64000);
    expect(intent['preferredInstructions'], 'Answer briefly.');
    expect(intent['preferredEnvironment'], '/work');
  });
}
