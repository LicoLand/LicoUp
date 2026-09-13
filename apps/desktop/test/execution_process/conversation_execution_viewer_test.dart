import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/features/agents/ui/execution_process/conversation_execution_viewer.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

const _searchKey = Key('execution-process-search');
const _listKey = Key('execution-process-records');

void main() {
  testWidgets('opens at latest, follows append, and preserves manual reading', (
    tester,
  ) async {
    final records = _records(80);
    final source = ValueNotifier(
      ConversationExecutionSnapshot(records: records),
    );
    addTearDown(source.dispose);
    await tester.pumpWidget(_app(_viewer(source)));
    await tester.pumpAndSettle();
    final scroll = tester.widget<ListView>(find.byKey(_listKey)).controller!;
    expect(scroll.position.extentAfter, lessThan(1));
    expect(
      find.byKey(const ValueKey('execution-process-text-event-79-0')),
      findsOneWidget,
    );

    source.value = ConversationExecutionSnapshot(records: _records(81));
    await tester.pumpAndSettle();
    expect(scroll.position.extentAfter, lessThan(1));
    expect(
      find.byKey(const ValueKey('execution-process-text-event-80-0')),
      findsOneWidget,
    );

    await tester.drag(find.byKey(_listKey), const Offset(0, 400));
    await tester.pumpAndSettle();
    final readingOffset = scroll.offset;
    source.value = ConversationExecutionSnapshot(records: _records(82));
    await tester.pumpAndSettle();
    expect(scroll.offset, closeTo(readingOffset, 0.1));
    expect(find.byKey(const Key('execution-process-latest')), findsOneWidget);

    await tester.tap(find.byKey(const Key('execution-process-latest')));
    await tester.pumpAndSettle();
    expect(scroll.position.extentAfter, lessThan(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('search reaches unmounted history and cycles every occurrence', (
    tester,
  ) async {
    final source = ValueNotifier(
      ConversationExecutionSnapshot(
        records: [
          const ConversationExecutionRecord(
            id: 'first',
            kind: 'unknown.event',
            rawText: 'needle alpha needle\r\n  {"unknown":"kept"}  ',
          ),
          ..._records(120),
          const ConversationExecutionRecord(
            id: 'last',
            rawText: 'final NEEDLE',
          ),
        ],
      ),
    );
    addTearDown(source.dispose);
    await tester.pumpWidget(_app(_viewer(source)));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('execution-process-text-first-0')),
      findsNothing,
    );

    await tester.enterText(find.byKey(_searchKey), 'needle');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('execution-process-text-first-0')),
      findsOneWidget,
    );
    expect(find.text('1 / 3'), findsOneWidget);
    final text = tester.widget<Text>(
      find.byKey(const ValueKey('execution-process-text-first-0')),
    );
    expect(
      text.textSpan!.toPlainText(),
      'needle alpha needle\r\n  {"unknown":"kept"}  ',
    );
    expect(
      (text.textSpan! as TextSpan).children!.whereType<TextSpan>().where(
        (span) => span.style?.backgroundColor != null,
      ),
      hasLength(2),
    );

    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.text('2 / 3'), findsOneWidget);
    await tester.tap(find.byKey(const Key('execution-process-next-match')));
    await tester.pumpAndSettle();
    expect(find.text('3 / 3'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('execution-process-text-last-0')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('execution-process-next-match')));
    await tester.pumpAndSettle();
    expect(find.text('1 / 3'), findsOneWidget);
    final scroll = tester.widget<ListView>(find.byKey(_listKey)).controller!;
    final searchedOffset = scroll.offset;
    source.value = ConversationExecutionSnapshot(
      records: [
        ...source.value.records,
        const ConversationExecutionRecord(id: 'append', rawText: 'live needle'),
      ],
    );
    await tester.pumpAndSettle();
    expect(scroll.offset, closeTo(searchedOffset, 0.1));
    expect(find.text('1 / 4'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long tool output remains searchable and copied byte-for-byte', (
    tester,
  ) async {
    final raw =
        '  \t{"unknown_field":true}\r\n'
        '${'x' * 70000}\r\n'
        'last-marker\r\n\r\n  ';
    final copied = <String>[];
    final source = ValueNotifier(
      ConversationExecutionSnapshot(
        records: [ConversationExecutionRecord(id: 'long', rawText: raw)],
      ),
    );
    addTearDown(source.dispose);
    await tester.pumpWidget(
      _app(_viewer(source, onCopyText: (value) async => copied.add(value))),
    );
    await tester.pumpAndSettle();
    expect(
      find
          .byWidgetPredicate(
            (widget) =>
                widget is Text &&
                widget.key.toString().contains('execution-process-text-long-'),
          )
          .evaluate()
          .length,
      lessThan(10),
    );
    await tester.enterText(find.byKey(_searchKey), 'unknown_field');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    final scroll = tester.widget<ListView>(find.byKey(_listKey)).controller!;
    scroll.jumpTo(0);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('execution-process-copy-long')));
    await tester.pump();
    expect(copied, [raw]);

    await tester.enterText(find.byKey(_searchKey), 'last-marker');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.text('1 / 1'), findsOneWidget);
    expect(scroll.offset, greaterThan(1000));
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow surface supports 200 percent type and loading updates', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(340, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final source = ValueNotifier(
      const ConversationExecutionSnapshot(loading: true),
    );
    addTearDown(source.dispose);
    await tester.pumpWidget(
      _app(_viewer(source), scale: 2, locale: const Locale('zh')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('execution-process-loading')), findsOneWidget);
    source.value = ConversationExecutionSnapshot(records: _records(4));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('execution-process-loading')), findsNothing);
    await tester.enterText(find.byKey(_searchKey), 'event');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('execution-process-match-count')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Escape and close restore focus to the supplied trigger', (
    tester,
  ) async {
    final source = ValueNotifier(
      ConversationExecutionSnapshot(records: _records(1)),
    );
    final trigger = FocusNode();
    addTearDown(source.dispose);
    addTearDown(trigger.dispose);
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => TextButton(
            focusNode: trigger,
            onPressed: () => showConversationExecutionViewer(
              context: context,
              source: source,
              agentIcon: const Icon(Icons.smart_toy_outlined),
              agentName: 'Fixture Agent',
              conversationTitle: 'Synthetic execution',
              onCopyText: (_) async {},
              returnFocusNode: trigger,
            ),
            child: const Text('Open'),
          ),
        ),
        reduceMotion: false,
      ),
    );
    trigger.requestFocus();
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_searchKey));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(ConversationExecutionViewer), findsNothing);
    expect(trigger.hasFocus, isTrue);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('execution-process-close')));
    await tester.pumpAndSettle();
    expect(trigger.hasFocus, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard selection copy uses the supplied platform callback', (
    tester,
  ) async {
    final copied = <String>[];
    final source = ValueNotifier(
      const ConversationExecutionSnapshot(
        records: [
          ConversationExecutionRecord(
            id: 'selection',
            rawText: 'copy this synthetic selection',
          ),
        ],
      ),
    );
    addTearDown(source.dispose);
    await tester.pumpWidget(
      _app(_viewer(source, onCopyText: (value) async => copied.add(value))),
    );
    await tester.pumpAndSettle();
    final region = tester.state<SelectableRegionState>(
      find.byType(SelectableRegion),
    );
    region.selectAll(SelectionChangedCause.keyboard);
    await tester.pump();
    Actions.invoke(region.context, CopySelectionTextIntent.copy);
    await tester.pump();
    expect(copied, ['copy this synthetic selection']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long loading errors remain scrollable and exactly copyable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(340, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final error = '  Fixture load failure\r\n${'detail\r\n' * 100}  ';
    final copied = <String>[];
    final source = ValueNotifier(
      ConversationExecutionSnapshot(records: _records(1), error: error),
    );
    addTearDown(source.dispose);
    await tester.pumpWidget(
      _app(
        _viewer(source, onCopyText: (value) async => copied.add(value)),
        scale: 2,
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(const Key('execution-process-error')))
          .data,
      error,
    );
    await tester.tap(find.byKey(const Key('execution-process-copy-error')));
    await tester.pump();
    expect(copied, [error]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'pending layout keeps search usable and only publishes newest data',
    (tester) async {
      final source = ValueNotifier(
        ConversationExecutionSnapshot(
          records: [
            const ConversationExecutionRecord(
              id: 'oldest-match',
              rawText: 'oldest needle',
            ),
            ..._records(5000),
          ],
        ),
      );
      addTearDown(source.dispose);
      await tester.pumpWidget(_app(_viewer(source)));
      expect(
        find.byKey(const Key('execution-process-preparing')),
        findsOneWidget,
      );
      final field = tester.widget<TextField>(find.byKey(_searchKey));
      field.controller!.text = 'oldest needle';
      field.onChanged!('oldest needle');
      field.onSubmitted!('oldest needle');
      // Replace the snapshot and geometry while the first batch is suspended.
      source.value = ConversationExecutionSnapshot(
        records: [
          const ConversationExecutionRecord(
            id: 'obsolete',
            rawText: 'discarded',
          ),
          ..._records(6000),
        ],
      );
      source.value = ConversationExecutionSnapshot(
        records: [
          const ConversationExecutionRecord(
            id: 'newest-match',
            rawText: 'oldest needle',
          ),
          ..._records(800),
        ],
      );
      tester.view.physicalSize = const Size(650, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('execution-process-preparing')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('execution-process-text-newest-match-0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('execution-process-text-obsolete-0')),
        findsNothing,
      );
      expect(find.text('1 / 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('disposing an in-progress layout discards pending batches', (
    tester,
  ) async {
    final source = ValueNotifier(
      ConversationExecutionSnapshot(records: _records(5000)),
    );
    addTearDown(source.dispose);
    await tester.pumpWidget(_app(_viewer(source)));
    expect(
      find.byKey(const Key('execution-process-preparing')),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('resizing preserves the raw record being read', (tester) async {
    tester.view.physicalSize = const Size(900, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final source = ValueNotifier(
      ConversationExecutionSnapshot(records: _records(120)),
    );
    addTearDown(source.dispose);
    await tester.pumpWidget(_app(_viewer(source)));
    await tester.pumpAndSettle();
    await tester.drag(find.byKey(_listKey), const Offset(0, 420));
    await tester.pumpAndSettle();
    final viewport = tester.getRect(find.byKey(_listKey));
    final texts = find.byWidgetPredicate(
      (widget) =>
          widget is Text &&
          widget.key.toString().contains('execution-process-text-event-'),
    );
    final visibleText =
        texts.evaluate().firstWhere((element) {
              final rect = tester.getRect(find.byWidget(element.widget));
              return rect.bottom > viewport.top && rect.top < viewport.bottom;
            }).widget
            as Text;
    tester.view.physicalSize = const Size(340, 720);
    await tester.pump();
    await tester.pumpAndSettle();
    final restored = find.byKey(visibleText.key!);
    expect(restored, findsOneWidget);
    final restoredRect = tester.getRect(restored);
    final resizedViewport = tester.getRect(find.byKey(_listKey));
    expect(restoredRect.bottom, greaterThan(resizedViewport.top));
    expect(restoredRect.top, lessThan(resizedViewport.bottom));
    expect(find.byKey(const Key('execution-process-latest')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'continuous appends complete the active prefix without restarting',
    (tester) async {
      final source = ValueNotifier(
        ConversationExecutionSnapshot(records: _records(500)),
      );
      addTearDown(source.dispose);
      var yields = 0;
      await tester.pumpWidget(
        _app(
          ConversationExecutionViewer(
            source: source,
            agentIcon: const Icon(Icons.smart_toy_outlined),
            agentName: 'Fixture Agent',
            conversationTitle: 'Synthetic stream',
            onCopyText: (_) async {},
            onClose: () {},
            layoutYield: () async {
              yields += 1;
              if (yields <= 125) {
                source.value = ConversationExecutionSnapshot(
                  records: [
                    ...source.value.records,
                    ConversationExecutionRecord(
                      id: 'stream-$yields',
                      rawText: 'Synthetic appended record $yields',
                    ),
                  ],
                );
              }
              await Future<void>.delayed(Duration.zero);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(source.value.records, hasLength(625));
      // 125 batches lay out the original prefix; only 31 more are needed for
      // its appended tail. Restarting on each append would exceed 280 batches.
      expect(yields, lessThan(180));
      expect(
        find.byKey(const ValueKey('execution-process-text-stream-125-0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('execution-process-preparing')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );
}

List<ConversationExecutionRecord> _records(int count) => [
  for (var index = 0; index < count; index++)
    ConversationExecutionRecord(
      id: 'event-$index',
      kind: 'tool.output',
      timestamp: '2026-01-01T09:00:00Z',
      rawText:
          '{"type":"tool.output","event":$index,\n'
          ' "result":"Synthetic result $index","unknown":{"kept":true}}',
    ),
];

Widget _viewer(
  ValueNotifier<ConversationExecutionSnapshot> source, {
  Future<void> Function(String)? onCopyText,
}) => ConversationExecutionViewer(
  source: source,
  agentIcon: const Icon(Icons.smart_toy_outlined),
  agentName: 'Fixture Agent',
  conversationTitle: 'Synthetic execution',
  onCopyText: onCopyText ?? (_) async {},
  onClose: () {},
);

Widget _app(
  Widget child, {
  double scale = 1,
  Locale locale = const Locale('en'),
  bool reduceMotion = true,
}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  locale: locale,
  supportedLocales: LicoStrings.supportedLocales,
  localizationsDelegates: const [
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ],
  theme: buildLicoTheme(platformBrightness: Brightness.dark),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: TextScaler.linear(scale),
      disableAnimations: reduceMotion,
    ),
    child: child!,
  ),
  home: Scaffold(body: child),
);
