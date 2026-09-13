import 'dart:collection';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/adaptive_flywheel_multi_capsule_section.dart';
import 'package:licoup/src/frontend/features/agents/ui/adaptive_flywheel_renderer_models.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

class _CountingModels extends ListBase<Map<String, dynamic>> {
  _CountingModels(this.values);

  final List<Map<String, dynamic>> values;
  int reads = 0;

  @override
  int get length => values.length;
  @override
  set length(int value) => throw UnsupportedError('Synthetic catalog snapshot');
  @override
  Map<String, dynamic> operator [](int index) {
    reads++;
    return values[index];
  }

  @override
  void operator []=(int index, Map<String, dynamic> value) =>
      throw UnsupportedError('Synthetic catalog snapshot');
}

TargetCandidate _target(List<Map<String, dynamic>> models) => TargetCandidate(
  target: 'synthetic-agent',
  label: 'Synthetic Agent',
  kind: 'cli',
  status: 'detected',
  configured: true,
  confidence: 1,
  adapterStatus: 'implemented',
  adapterCapabilities: const {'conversationDriver': 'implemented'},
  modelCatalog: {'models': models},
);

List<Map<String, dynamic>> _models(int count) => [
  for (var index = 0; index < count; index++)
    {
      'name': 'model-$index',
      'displayName': 'Synthetic Model $index',
      'providerId': 'provider-${index ~/ 100}',
      'provider': 'Provider ${index ~/ 100}',
      'reasoningEfforts': ['low', 'high'],
    },
];

Future<void> _pumpAssistant(
  WidgetTester tester, {
  required ValueNotifier<TargetCandidate> target,
  String selectedModel = '',
  double textScale = 1,
  ValueChanged<DailyConversationAgentAssignment>? onChanged,
  ValueChanged<String>? onCatalogRequested,
}) async {
  tester.view.physicalSize = const Size(1200, 700);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      supportedLocales: LicoStrings.supportedLocales,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      theme: buildLicoTheme(platformBrightness: Brightness.dark),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: Center(
          child: ValueListenableBuilder<TargetCandidate>(
            valueListenable: target,
            builder: (context, target, _) => AgentRuntimeAssignmentCascadeCards(
              keyPrefix: 'assistant',
              showFast: false,
              borderRadius: BorderRadius.circular(12),
              maxHeight: 190,
              modelCardWidth: 288,
              targets: [target],
              draft: DailyConversationAgentAssignment(
                agentId: target.target,
                modelName: selectedModel,
              ),
              selectedAgentIds: {target.target},
              onDraftChanged: onChanged ?? (_) {},
              onAgentCatalogRequested: onCatalogRequested,
              revealSelectionOnOpen: true,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test(
    'catalog projection reuses native input and changes with its replacement',
    () {
      final models = _CountingModels(_models(2000));
      final target = _target(models);
      final cache = AgentOrchestrationModelCatalogCache();
      final catalog = cache.forTarget(target);
      expect(models.reads, 2000);
      expect(catalog.displayName('model-1999'), 'Synthetic Model 1999');
      expect(catalog.groups.last.models.last, 'model-1999');
      expect(catalog.reasoningEfforts('model-1999'), ['low', 'high']);
      expect(catalog.matchingGroups('1999').single.models, ['model-1999']);
      expect(
        cache.forTarget(target.withModelCatalog(target.modelCatalog)),
        same(catalog),
      );
      expect(models.reads, 2000);

      final replacement = cache.forTarget(
        target.withModelCatalog({
          'models': [
            {'name': 'model-1999', 'displayName': 'Revised Native Label'},
          ],
        }),
      );
      expect(replacement, isNot(same(catalog)));
      expect(replacement.models, ['model-1999']);
      expect(replacement.displayName('model-1999'), 'Revised Native Label');
      expect(models.reads, 2000);
    },
  );

  testWidgets(
    '2000 models build viewport rows without rereading on scroll or hover',
    (tester) async {
      final models = _CountingModels(_models(2000));
      final target = ValueNotifier(_target(models));
      addTearDown(target.dispose);
      final requested = <String>[];
      var modelBuilds = 0;
      final previousBuildHook = debugOnRebuildDirtyWidget;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        previousBuildHook?.call(element, builtOnce);
        final widget = element.widget;
        if (widget is Text &&
            (widget.data ?? '').startsWith('Synthetic Model ')) {
          modelBuilds++;
        }
      };
      addTearDown(() => debugOnRebuildDirtyWidget = previousBuildHook);

      await _pumpAssistant(
        tester,
        target: target,
        onCatalogRequested: requested.add,
      );
      expect(modelBuilds, inExclusiveRange(0, 60));
      expect(models.reads, 2000);
      final initialRequests = requested.length;
      final list = find.byKey(const Key('assistant-model-list'));
      final controller = tester.widget<ListView>(list).controller!;
      final searchPosition = tester.getTopLeft(
        find.byKey(const Key('assistant-model-search')),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);

      for (final fraction in [0.25, 0.75, 0.5, 0.0]) {
        modelBuilds = 0;
        controller.jumpTo(controller.position.maxScrollExtent * fraction);
        await tester.pump();
        await mouse.moveTo(tester.getCenter(list));
        await tester.pumpAndSettle();
        expect(modelBuilds, lessThan(100));
        expect(models.reads, 2000);
        expect(requested.length, initialRequests);
        expect(
          find.textContaining('Synthetic Model ').evaluate().length,
          lessThanOrEqualTo(40),
        );
        expect(
          tester.getTopLeft(find.byKey(const Key('assistant-model-search'))),
          searchPosition,
        );
      }

      modelBuilds = 0;
      target.value = target.value.withModelCatalog(target.value.modelCatalog);
      await tester.pump();
      expect(models.reads, 2000);
      expect(modelBuilds, lessThan(60));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'last saved model is visible without building preceding rows and remains searchable',
    (tester) async {
      final models = _CountingModels(_models(2000));
      final target = ValueNotifier(_target(models));
      addTearDown(target.dispose);
      DailyConversationAgentAssignment? picked;
      await _pumpAssistant(
        tester,
        target: target,
        selectedModel: 'model-1999',
        onChanged: (value) => picked = value,
      );
      final selected = find.byKey(
        const Key('assistant-model-synthetic-agent-model-1999'),
      );
      final viewport = tester.getRect(
        find.byKey(const Key('assistant-model-list')),
      );
      expect(tester.getRect(selected).top, greaterThanOrEqualTo(viewport.top));
      expect(
        tester.getRect(selected).bottom,
        lessThanOrEqualTo(viewport.bottom),
      );
      expect(
        find.byKey(const Key('assistant-model-synthetic-agent-model-0')),
        findsNothing,
      );
      expect(
        find.textContaining('Synthetic Model ').evaluate().length,
        lessThanOrEqualTo(40),
      );

      await tester.enterText(
        find.byKey(const Key('assistant-model-search')),
        'MODEL 1234',
      );
      await tester.pumpAndSettle();
      expect(find.text('Synthetic Model 1234'), findsOneWidget);
      expect(find.text('Provider 12'), findsOneWidget);
      expect(models.reads, 2000);
      // Tab from the pinned search into the filtered model list, then activate
      // the InkWell through the same keyboard action as the eager picker.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(picked?.modelName, 'model-1234');
      expect(picked?.agentId, 'synthetic-agent');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'wrapped native labels retain their full row height at larger text scale',
    (tester) async {
      final target = ValueNotifier(
        _target([
          {
            'name': 'opaque/model-id',
            'displayName':
                'A Native Model Label With Several Words And A Long Context Window',
            'provider': 'Synthetic Provider',
          },
          {'name': 'short', 'displayName': 'Short Model'},
        ]),
      );
      addTearDown(target.dispose);
      await _pumpAssistant(
        tester,
        target: target,
        selectedModel: 'opaque/model-id',
        textScale: 1.5,
      );
      final longRow = find.byKey(
        const Key('assistant-model-synthetic-agent-opaque/model-id'),
      );
      final shortRow = find.byKey(
        const Key('assistant-model-synthetic-agent-short'),
      );
      expect(tester.getSize(longRow).height, greaterThan(32));
      expect(
        tester.getRect(longRow).bottom,
        lessThanOrEqualTo(tester.getRect(shortRow).top),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
