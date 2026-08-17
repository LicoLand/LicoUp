import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/application/features/agents/adaptive_flywheel/adaptive_flywheel_editor_models.dart';
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
}
