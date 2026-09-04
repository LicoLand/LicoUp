import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/frontend/features/agents/ui/adaptive_flywheel_renderer_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/adaptive_flywheel_multi_capsule_section.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

TargetCandidate _target({
  required String id,
  required String label,
  required List<Map<String, dynamic>> models,
}) {
  return TargetCandidate(
    target: id,
    label: label,
    kind: 'cli',
    status: 'detected',
    configured: true,
    confidence: 1,
    binaryPath: '/synthetic/bin/$id',
    adapterStatus: 'implemented',
    adapterCapabilities: const {'conversationDriver': 'implemented'},
    modelCatalog: {'models': models},
  );
}

Future<void> _pumpSection(
  WidgetTester tester, {
  required List<TargetCandidate> targets,
  bool Function(String agentId)? isRefreshingAgentCatalog,
  ValueChanged<String>? onAgentCatalogRequested,
}) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('zh'),
      supportedLocales: LicoStrings.supportedLocales,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      theme: buildLicoTheme(platformBrightness: Brightness.dark),
      home: Scaffold(
        body: SingleChildScrollView(
          child: AdaptiveFlywheelMultiCapsuleSection(
            title: 'Actors',
            keyPrefix: 'flywheel-actors',
            idPrefix: 'actor',
            assignments: const <DailyConversationAgentAssignment>[],
            targets: targets,
            onChanged: (_) {},
            isRefreshingAgentCatalog: isRefreshingAgentCatalog,
            onAgentCatalogRequested: onAgentCatalogRequested,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('hides the reasoning-effort card when the catalog has none', (
    tester,
  ) async {
    await _pumpSection(
      tester,
      targets: [
        _target(
          id: 'cursor',
          label: 'Cursor',
          models: const [
            {
              'name': 'fable-5-1m-medium',
              'displayName': 'Fable 5 1M Medium',
              'reasoningEfforts': <String>[],
            },
            {
              'name': 'fable-5-1m-high',
              'displayName': 'Fable 5 1M High',
              'reasoningEfforts': <String>[],
            },
          ],
        ),
      ],
    );

    await tester.tap(find.byKey(const Key('flywheel-actors-add')));
    await tester.pumpAndSettle();

    expect(find.text('Fable 5 1M Medium'), findsOneWidget);
    expect(find.text('Fable 5 1M High'), findsOneWidget);
    expect(
      find.byKey(const Key('flywheel-actors-settings-card')),
      findsNothing,
    );
    expect(find.text('思考强度'), findsNothing);
    expect(find.text('未发现思考强度'), findsNothing);
  });

  testWidgets('keeps the effort card when independent efforts exist', (
    tester,
  ) async {
    await _pumpSection(
      tester,
      targets: [
        _target(
          id: 'codex',
          label: 'Codex',
          models: const [
            {
              'name': 'gpt-5.5',
              'displayName': 'GPT-5.5',
              'reasoningEfforts': ['low', 'high'],
            },
          ],
        ),
      ],
    );

    await tester.tap(find.byKey(const Key('flywheel-actors-add')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('flywheel-actors-settings-card')),
      findsOneWidget,
    );
    expect(find.text('思考强度'), findsOneWidget);
  });

  testWidgets('renders model groups from provider metadata', (tester) async {
    await _pumpSection(
      tester,
      targets: [
        _target(
          id: 'kilo-code',
          label: 'Kilo Code',
          models: const [
            {
              'name': 'opaque-one/model-a',
              'displayName': 'Model A',
              'providerId': 'opaque-one',
              'provider': 'Provider One',
            },
            {
              'name': 'opaque-two/model-b',
              'displayName': 'Model B',
              'providerId': 'opaque-two',
              'provider': 'Provider Two',
            },
          ],
        ),
      ],
    );

    await tester.tap(find.byKey(const Key('flywheel-actors-add')));
    await tester.pumpAndSettle();

    expect(find.text('Provider One'), findsOneWidget);
    expect(find.text('Provider Two'), findsOneWidget);
    expect(find.text('Model A'), findsOneWidget);
    expect(find.text('Model B'), findsOneWidget);
  });

  testWidgets('renders the provider for one configured Claude model', (
    tester,
  ) async {
    await _pumpSection(
      tester,
      targets: [
        _target(
          id: 'claude-code',
          label: 'Claude Code',
          models: const [
            {
              'name': 'deepseek-v4-flash',
              'displayName': 'DeepSeek V4 Flash',
              'providerId': 'deepseek',
              'provider': 'DeepSeek',
            },
          ],
        ),
      ],
    );

    await tester.tap(find.byKey(const Key('flywheel-actors-add')));
    await tester.pumpAndSettle();

    expect(find.text('DeepSeek'), findsOneWidget);
    expect(find.text('DeepSeek V4 Flash'), findsOneWidget);
  });

  testWidgets('requests a native catalog when an agent becomes active', (
    tester,
  ) async {
    final requested = <String>[];
    await _pumpSection(
      tester,
      targets: [
        _target(id: 'cursor', label: 'Cursor', models: const []),
        _target(id: 'kilo-code', label: 'Kilo Code', models: const []),
      ],
      onAgentCatalogRequested: requested.add,
    );

    await tester.tap(find.byKey(const Key('flywheel-actors-add')));
    await tester.pump();
    expect(requested, contains('cursor'));

    await tester.tap(find.byKey(const Key('flywheel-actors-option-kilo-code')));
    await tester.pump();
    expect(requested, contains('kilo-code'));
  });

  testWidgets('animates while the active native catalog is loading', (
    tester,
  ) async {
    await _pumpSection(
      tester,
      targets: [
        _target(id: 'antigravity', label: 'Antigravity', models: const []),
      ],
      isRefreshingAgentCatalog: (agentId) => agentId == 'antigravity',
    );

    await tester.tap(find.byKey(const Key('flywheel-actors-add')));
    await tester.pump();

    expect(
      find.byKey(const Key('flywheel-actors-model-loading')),
      findsOneWidget,
    );
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets('filters models by a case-insensitive contains query', (
    tester,
  ) async {
    await _pumpSection(
      tester,
      targets: [
        _target(
          id: 'claude-code',
          label: 'Claude Code',
          models: const [
            {
              'name': 'claude-opus-5',
              'displayName': 'Claude Opus 5',
              'reasoningEfforts': ['high'],
            },
            {
              'name': 'claude-sonnet-5',
              'displayName': 'Claude Sonnet 5',
              'reasoningEfforts': ['high'],
            },
            {
              'name': 'gpt-5.5',
              'displayName': 'GPT-5.5',
              'reasoningEfforts': ['low'],
            },
          ],
        ),
      ],
    );

    await tester.tap(find.byKey(const Key('flywheel-actors-add')));
    await tester.pumpAndSettle();

    expect(find.text('Claude Opus 5'), findsOneWidget);
    expect(find.text('Claude Sonnet 5'), findsOneWidget);
    expect(find.text('GPT-5.5'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('flywheel-actors-model-search')),
      'CLAUDE',
    );
    await tester.pump();

    expect(find.text('Claude Opus 5'), findsOneWidget);
    expect(find.text('Claude Sonnet 5'), findsOneWidget);
    expect(find.text('GPT-5.5'), findsNothing);

    await tester.tap(
      find.byKey(const Key('flywheel-actors-model-search-clear')),
    );
    await tester.pump();
    expect(find.text('GPT-5.5'), findsOneWidget);
  });

  testWidgets('keeps the confirmed model efforts while hovering other models', (
    tester,
  ) async {
    await _pumpSection(
      tester,
      targets: [
        _target(
          id: 'codex',
          label: 'Codex',
          models: const [
            {
              'name': 'm-a',
              'displayName': 'Model A',
              'reasoningEfforts': ['low'],
            },
            {
              'name': 'm-b',
              'displayName': 'Model B',
              'reasoningEfforts': ['xhigh'],
            },
          ],
        ),
      ],
    );

    await tester.tap(find.byKey(const Key('flywheel-actors-add')));
    await tester.pumpAndSettle();

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);

    // Before any model is confirmed, hovering previews that model's efforts.
    await mouse.moveTo(
      tester.getCenter(
        find.byKey(const Key('flywheel-actors-model-codex-m-b')),
      ),
    );
    await tester.pump();
    expect(
      find.byKey(const Key('flywheel-actors-effort-codex-xhigh')),
      findsOneWidget,
    );

    // Confirm Model A: the effort card now belongs to the confirmed model.
    await tester.tap(find.byKey(const Key('flywheel-actors-model-codex-m-a')));
    await tester.pump();
    expect(
      find.byKey(const Key('flywheel-actors-effort-codex-low')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('flywheel-actors-effort-codex-xhigh')),
      findsNothing,
    );

    // Sliding the mouse over another model must not re-point the effort card.
    await mouse.moveTo(
      tester.getCenter(
        find.byKey(const Key('flywheel-actors-model-codex-m-a')),
      ),
    );
    await tester.pump();
    await mouse.moveTo(
      tester.getCenter(
        find.byKey(const Key('flywheel-actors-model-codex-m-b')),
      ),
    );
    await tester.pump();
    expect(
      find.byKey(const Key('flywheel-actors-effort-codex-low')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('flywheel-actors-effort-codex-xhigh')),
      findsNothing,
    );
  });

  testWidgets('scrolls each column to the persisted selection on open', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final models = <Map<String, dynamic>>[
      for (var index = 0; index < 24; index += 1)
        {
          'name': 'model-$index',
          'displayName': 'Model $index',
          'reasoningEfforts': ['low', 'high'],
        },
    ];
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        supportedLocales: LicoStrings.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        theme: buildLicoTheme(platformBrightness: Brightness.dark),
        home: Scaffold(
          body: Center(
            child: AgentRuntimeAssignmentCascadeCards(
              keyPrefix: 'assistant',
              showFast: false,
              borderRadius: BorderRadius.circular(12),
              maxHeight: 190,
              targets: [
                _target(
                  id: 'claude-code',
                  label: 'Claude Code',
                  models: models,
                ),
              ],
              draft: const DailyConversationAgentAssignment(
                agentId: 'claude-code',
                modelName: 'model-23',
                reasoningEffort: 'high',
              ),
              selectedAgentIds: const {'claude-code'},
              onDraftChanged: (_) {},
              revealSelectionOnOpen: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Without the reveal, the last of 24 models sits below the viewport.
    final modelCard = tester.getRect(
      find.byKey(const Key('assistant-model-card')),
    );
    final selectedModel = tester.getRect(
      find.byKey(const Key('assistant-model-claude-code-model-23')),
    );
    expect(selectedModel.top, greaterThanOrEqualTo(modelCard.top));
    expect(selectedModel.bottom, lessThanOrEqualTo(modelCard.bottom));
  });
}
