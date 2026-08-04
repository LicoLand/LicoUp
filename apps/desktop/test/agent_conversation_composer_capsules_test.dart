import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_composer_capsules.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

void _useComposerPopoverViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _tapRuntimeSelectorRow(WidgetTester tester, Key rowKey) async {
  final inkWell = find.descendant(
    of: find.byKey(rowKey),
    matching: find.byType(InkWell),
  );
  expect(inkWell, findsOneWidget);
  final widget = tester.widget<InkWell>(inkWell);
  widget.onTap?.call();
  await tester.pumpAndSettle();
}

void main() {
  test('shortenComposerModelName keeps short ids intact', () {
    expect(shortenComposerModelName('gpt-5.4-mini'), 'gpt-5.4-mini');
  });

  test('shortenComposerModelName uses the trailing segment after slash', () {
    expect(shortenComposerModelName('providers/openai/gpt-5.5'), 'gpt-5.5');
  });

  test('shortenComposerModelName middle-ellipsizes long ids', () {
    expect(
      shortenComposerModelName('a-very-long-model-name-for-testing'),
      'a-very-long-model-name-fo…',
    );
  });

  test('composeRuntimeCapsuleLabel joins model and effort', () {
    expect(
      composeRuntimeCapsuleLabel(model: 'gpt-5.6-sol', effort: 'medium'),
      'gpt-5.6-sol Medium',
    );
  });

  test('formatComposerReasoningEffortLabel title-cases effort tokens', () {
    expect(formatComposerReasoningEffortLabel('high'), 'High');
  });

  testWidgets('ComposerRuntimeCapsule reports model submenu selection', (
    tester,
  ) async {
    _useComposerPopoverViewport(tester);
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(platformBrightness: Brightness.dark),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomLeft,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: ComposerRuntimeCapsule(
                modelOptions: const ['gpt-5.4-mini', 'gpt-5.5'],
                selectedModel: 'gpt-5.4-mini',
                defaultModel: '',
                enabled: true,
                onModelChanged: (value) => selected = value,
                reasoningEffortOptions: const [],
                selectedReasoningEffort: '',
                onReasoningEffortChanged: null,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('conversation-model-button')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('conversation-runtime-selector-panel')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('conversation-runtime-submenu')), findsNothing);
    await _tapRuntimeSelectorRow(
      tester,
      const Key('conversation-runtime-model-row'),
    );
    expect(
      find.byKey(const Key('conversation-runtime-submenu')),
      findsOneWidget,
    );
    expect(find.text('gpt-5.5'), findsOneWidget);
    await tester.tap(find.text('gpt-5.5'));
    await tester.pumpAndSettle();
    expect(selected, 'gpt-5.5');
  });

  testWidgets('ComposerRuntimeCapsule shows model and effort in label', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(platformBrightness: Brightness.dark),
        home: Scaffold(
          body: ComposerRuntimeCapsule(
            modelOptions: const ['gpt-5.6-sol'],
            selectedModel: 'gpt-5.6-sol',
            defaultModel: '',
            enabled: true,
            onModelChanged: (_) {},
            reasoningEffortOptions: const ['medium'],
            selectedReasoningEffort: 'medium',
            onReasoningEffortChanged: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('gpt-5.6-sol Medium'), findsOneWidget);
  });

  testWidgets('ComposerRuntimeCapsule labels an unset model as the default', (
    tester,
  ) async {
    _useComposerPopoverViewport(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(platformBrightness: Brightness.dark),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomLeft,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: ComposerRuntimeCapsule(
                modelOptions: const ['auto', 'composer-2.5'],
                selectedModel: '',
                defaultModel: 'auto',
                enabled: true,
                onModelChanged: (_) {},
                reasoningEffortOptions: const [],
                selectedReasoningEffort: '',
                onReasoningEffortChanged: null,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // The capsule must not borrow the catalog default model id as its label.
    expect(find.text('Native default'), findsOneWidget);
    expect(find.text('composer-2.5'), findsNothing);

    await tester.tap(find.byKey(const Key('conversation-model-button')));
    await tester.pumpAndSettle();
    await _tapRuntimeSelectorRow(
      tester,
      const Key('conversation-runtime-model-row'),
    );
    // The default row carries the checkmark for the empty selection.
    final defaultRow = tester.widgetList<Icon>(
      find.byIcon(Icons.check_rounded),
    );
    expect(defaultRow, hasLength(1));
    expect(find.text('auto (default)'), findsOneWidget);
  });

  testWidgets('ComposerRuntimeCapsule reports effort submenu selection', (
    tester,
  ) async {
    _useComposerPopoverViewport(tester);
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(platformBrightness: Brightness.dark),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomLeft,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: ComposerRuntimeCapsule(
                modelOptions: const [],
                selectedModel: '',
                defaultModel: '',
                enabled: true,
                onModelChanged: null,
                reasoningEffortOptions: const ['low', 'high'],
                selectedReasoningEffort: 'low',
                onReasoningEffortChanged: (value) => selected = value,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('conversation-model-button')));
    await tester.pumpAndSettle();
    await _tapRuntimeSelectorRow(
      tester,
      const Key('conversation-runtime-effort-row'),
    );
    await tester.tap(find.text('High'));
    await tester.pumpAndSettle();
    expect(selected, 'high');
  });

  testWidgets('primary panel lists model and reasoning effort side by side', (
    tester,
  ) async {
    _useComposerPopoverViewport(tester);
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
          body: Align(
            alignment: Alignment.bottomLeft,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: ComposerRuntimeCapsule(
                modelOptions: const ['k3', 'k3-256k'],
                selectedModel: '',
                defaultModel: 'k3',
                enabled: true,
                onModelChanged: (_) {},
                reasoningEffortOptions: const ['low', 'high'],
                selectedReasoningEffort: '',
                onReasoningEffortChanged: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('conversation-model-button')));
    await tester.pumpAndSettle();

    final primaryCard = find.byKey(
      const Key('conversation-runtime-primary-card'),
    );
    final modelRow = find.byKey(const Key('conversation-runtime-model-row'));
    final effortRow = find.byKey(const Key('conversation-runtime-effort-row'));
    // Both controls are first-class siblings inside the one primary card.
    expect(
      find.descendant(of: primaryCard, matching: modelRow),
      findsOneWidget,
    );
    expect(
      find.descendant(of: primaryCard, matching: effortRow),
      findsOneWidget,
    );
    expect(find.text('Model'), findsOneWidget);
    expect(find.text('Reasoning Effort'), findsOneWidget);
    expect(
      tester.getRect(effortRow).top,
      greaterThan(tester.getRect(modelRow).top),
    );
    // A two-word control name must stay on one line, so both rows share the
    // same height and the primary card keeps its menu proportions.
    expect(tester.getSize(effortRow).height, tester.getSize(modelRow).height);
    // The effort row reads as Auto until the user picks an explicit effort.
    expect(find.text('Auto'), findsOneWidget);

    // Each row opens its own submenu without reshaping the primary card.
    final primaryRect = tester.getRect(primaryCard);
    await _tapRuntimeSelectorRow(
      tester,
      const Key('conversation-runtime-effort-row'),
    );
    expect(find.text('High'), findsOneWidget);
    expect(tester.getRect(primaryCard), primaryRect);

    await _tapRuntimeSelectorRow(
      tester,
      const Key('conversation-runtime-model-row'),
    );
    expect(find.text('k3-256k'), findsOneWidget);
    expect(find.text('High'), findsNothing);
    expect(tester.getRect(primaryCard), primaryRect);
  });

  testWidgets('primary panel labels both rows in Simplified Chinese', (
    tester,
  ) async {
    _useComposerPopoverViewport(tester);
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
          body: Align(
            alignment: Alignment.bottomLeft,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: ComposerRuntimeCapsule(
                modelOptions: const ['k3', 'k3-256k'],
                selectedModel: '',
                defaultModel: 'k3',
                enabled: true,
                onModelChanged: (_) {},
                reasoningEffortOptions: const ['low', 'medium', 'high'],
                selectedReasoningEffort: 'high',
                onReasoningEffortChanged: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('conversation-model-button')));
    await tester.pumpAndSettle();

    expect(find.text('模型'), findsOneWidget);
    expect(find.text('思考强度'), findsOneWidget);
    // The effort row summarizes the active effort with the product's own copy.
    expect(find.text('高'), findsWidgets);
  });

  testWidgets('effort submenu can return the turn to the native default', (
    tester,
  ) async {
    _useComposerPopoverViewport(tester);
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(platformBrightness: Brightness.dark),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomLeft,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: ComposerRuntimeCapsule(
                modelOptions: const [],
                selectedModel: '',
                defaultModel: '',
                enabled: true,
                onModelChanged: null,
                reasoningEffortOptions: const ['low', 'high'],
                selectedReasoningEffort: 'high',
                onReasoningEffortChanged: (value) => selected = value,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('conversation-model-button')));
    await tester.pumpAndSettle();
    await _tapRuntimeSelectorRow(
      tester,
      const Key('conversation-runtime-effort-row'),
    );
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('conversation-runtime-submenu')),
        matching: find.text('Auto'),
      ),
    );
    await tester.pumpAndSettle();
    expect(selected, '');
  });

  testWidgets(
    'ComposerRuntimeCapsule keeps submenu bounded for long catalogs',
    (tester) async {
      _useComposerPopoverViewport(tester);
      const options = [
        'gpt-5.6-terra-alpha',
        'gpt-5.6-terra-beta',
        'gpt-5.6-terra-gamma',
        'gpt-5.6-terra-delta',
        'gpt-5.6-terra-epsilon',
        'gpt-5.6-terra-zeta',
        'gpt-5.6-terra-eta',
        'gpt-5.6-terra-theta',
        'gpt-5.6-terra-iota',
        'gpt-5.6-terra-kappa',
        'gpt-5.6-terra-lambda',
        'gpt-5.6-terra-mu',
      ];
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLicoTheme(platformBrightness: Brightness.dark),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomLeft,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: ComposerRuntimeCapsule(
                  modelOptions: options,
                  selectedModel: options.first,
                  defaultModel: '',
                  enabled: true,
                  onModelChanged: (_) {},
                  reasoningEffortOptions: const [],
                  selectedReasoningEffort: '',
                  onReasoningEffortChanged: null,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(const Key('conversation-model-button')));
      await tester.pumpAndSettle();
      await _tapRuntimeSelectorRow(
        tester,
        const Key('conversation-runtime-model-row'),
      );

      final submenu = tester.getSize(
        find.byKey(const Key('conversation-runtime-submenu')),
      );
      expect(
        submenu.height,
        lessThanOrEqualTo(
          MessagingDesktopMetrics.composerRuntimeSelectorSubmenuMaxHeight + 1,
        ),
      );
      expect(find.byType(Scrollable), findsWidgets);
    },
  );

  testWidgets('submenu is a detached card with a gap from the primary', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(platformBrightness: Brightness.dark),
        home: Scaffold(
          body: Center(
            child: ComposerRuntimeCapsule(
              modelOptions: const ['a', 'b'],
              selectedModel: 'a',
              defaultModel: 'a',
              enabled: true,
              onModelChanged: (_) {},
              reasoningEffortOptions: const [],
              selectedReasoningEffort: '',
              onReasoningEffortChanged: null,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('conversation-model-button')));
    await tester.pumpAndSettle();
    await _tapRuntimeSelectorRow(
      tester,
      const Key('conversation-runtime-model-row'),
    );

    final primary = tester.getRect(
      find.byKey(const Key('conversation-runtime-primary-card')),
    );
    final submenu = tester.getRect(
      find.byKey(const Key('conversation-runtime-submenu')),
    );
    // Primary stays left; submenu is a separate card to the right with a gap.
    expect(submenu.left, greaterThan(primary.right + 4));
    expect(
      submenu.left - primary.right,
      closeTo(MessagingDesktopMetrics.composerRuntimeSelectorSubmenuGap, 2),
    );
    expect(
      primary.width,
      MessagingDesktopMetrics.composerRuntimeSelectorPrimaryWidth,
    );
    // Tall submenu must not lift the primary off the shared bottom baseline.
    expect((submenu.bottom - primary.bottom).abs(), lessThan(2));
  });

  testWidgets('ComposerCapsuleRow hides runtime capsule without catalogs', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(platformBrightness: Brightness.dark),
        home: const Scaffold(
          body: ComposerCapsuleRow(
            modelOptions: [],
            reasoningEffortOptions: [],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('conversation-model-button')), findsNothing);
  });
}
