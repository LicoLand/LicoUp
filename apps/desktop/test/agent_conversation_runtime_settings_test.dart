import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_client/src/frontend/features/agents/ui/agent_conversation_runtime_settings.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/shared/ui/apple_popup_select.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

void main() {
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
    expect(modelSelect.value, '');
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
}
