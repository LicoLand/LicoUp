import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/features/agents/conversation/conversation_runtime_options.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_runtime_settings.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/apple_popup_select.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

void main() {
  test('antigravity ignores stale reasoning-effort metadata', () {
    final target = TargetCandidate(
      target: 'antigravity',
      label: 'Antigravity',
      kind: 'native-history',
      status: 'detected',
      configured: true,
      confidence: 1,
      adapterStatus: 'implemented',
      adapterCapabilities: const {
        'reasoningEffortOptions': ['low', 'medium', 'high'],
      },
      modelCatalog: const {
        'models': [
          {
            'name': 'Gemini 3.5 Flash (High)',
            'reasoningEfforts': ['low', 'medium', 'high'],
          },
        ],
      },
    );

    expect(
      conversationReasoningEffortsForModel(target, 'Gemini 3.5 Flash (High)'),
      isEmpty,
    );
  });

  testWidgets('runtime settings expose independent model and effort ports', (
    tester,
  ) async {
    String? selectedModel;
    String? selectedEffort;

    await tester.pumpWidget(
      MaterialApp(
        supportedLocales: LicoStrings.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        theme: buildLicoTheme(platformBrightness: Brightness.dark),
        home: Scaffold(
          body: ConversationRuntimeSettingsBar(
            enabled: true,
            modelOptions: const ['model-fixture'],
            selectedModel: 'unknown-model',
            reasoningEffortOptions: const ['high'],
            selectedReasoningEffort: 'high',
            onModelChanged: (value) => selectedModel = value,
            onReasoningEffortChanged: (value) => selectedEffort = value,
          ),
        ),
      ),
    );

    final modelSelect = tester.widget<ApplePopupSelect<String>>(
      find.descendant(
        of: find.byKey(const ValueKey('conversation-model-select')),
        matching: find.byType(ApplePopupSelect<String>),
      ),
    );
    final effortSelect = tester.widget<ApplePopupSelect<String>>(
      find.descendant(
        of: find.byKey(const ValueKey('conversation-reasoning-select')),
        matching: find.byType(ApplePopupSelect<String>),
      ),
    );
    expect(modelSelect.value, isNull);
    expect(effortSelect.value, 'high');

    modelSelect.onChanged?.call('model-fixture');
    effortSelect.onChanged?.call('high');
    expect(selectedModel, 'model-fixture');
    expect(selectedEffort, 'high');
  });

  testWidgets('runtime settings omit selectors without catalog options', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        supportedLocales: LicoStrings.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        theme: buildLicoTheme(platformBrightness: Brightness.dark),
        home: ConversationRuntimeSettingsBar(
          enabled: false,
          modelOptions: const [],
          selectedModel: '',
          reasoningEffortOptions: const [],
          selectedReasoningEffort: '',
          onModelChanged: (_) {},
          onReasoningEffortChanged: (_) {},
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('conversation-model-select')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('conversation-reasoning-select')),
      findsNothing,
    );
  });

  testWidgets('model selector shows the configured default model name', (
    tester,
  ) async {
    String? selectedModel;
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
          body: ConversationRuntimeSettingsBar(
            enabled: true,
            modelOptions: const ['gpt-5.5', 'gpt-5.4-mini'],
            selectedModel: '',
            reasoningEffortOptions: const [],
            selectedReasoningEffort: '',
            onModelChanged: (value) => selectedModel = value,
            onReasoningEffortChanged: (_) {},
            defaultModel: 'gpt-5.5',
          ),
        ),
      ),
    );

    final modelSelect = tester.widget<ApplePopupSelect<String>>(
      find.descendant(
        of: find.byKey(const ValueKey('conversation-model-select')),
        matching: find.byType(ApplePopupSelect<String>),
      ),
    );
    expect(modelSelect.value, '');
    expect(
      modelSelect.options
          .map((option) => (option.value, option.label))
          .toList(),
      [('', 'gpt-5.5（默认）'), ('gpt-5.4-mini', 'gpt-5.4-mini')],
    );
    expect(find.text('gpt-5.5（默认）'), findsOneWidget);
    expect(find.text('模型 · gpt-5.5'), findsNothing);
    expect(find.text('模型 · 原生默认值'), findsNothing);
    modelSelect.onChanged?.call('');
    expect(selectedModel, '');
  });

  testWidgets('model selector discloses when the default was not detected', (
    tester,
  ) async {
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
          body: ConversationRuntimeSettingsBar(
            enabled: true,
            modelOptions: const ['gpt-5.5'],
            selectedModel: '',
            reasoningEffortOptions: const [],
            selectedReasoningEffort: '',
            onModelChanged: (_) {},
            onReasoningEffortChanged: (_) {},
          ),
        ),
      ),
    );

    final modelSelect = tester.widget<ApplePopupSelect<String>>(
      find.descendant(
        of: find.byKey(const ValueKey('conversation-model-select')),
        matching: find.byType(ApplePopupSelect<String>),
      ),
    );
    expect(modelSelect.value, isNull);
    expect(modelSelect.options, hasLength(1));
    expect(modelSelect.options.single.value, 'gpt-5.5');
    expect(find.text('未检测到默认模型'), findsOneWidget);
    expect(find.text('模型 · 未检测到默认模型'), findsNothing);
    expect(find.text('模型 · 原生默认值'), findsNothing);
  });
}
