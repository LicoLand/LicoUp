import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_runtime/presentation_runtime.dart';

import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_message_blocks.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_render_adapter.dart';
import 'package:licoup/src/frontend/shared/ui/message_markdown.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/conversation/conversation_markdown_port.dart';
import 'package:licoup/src/projections/conversation/conversation_markdown_presentation_source.dart';
import 'package:licoup/src/projections/conversation/conversation_markdown_preparation.dart';

import 'prepared_message_markdown_harness.dart';

/// Component-integration evidence for the prepared conversation message view.
///
/// Every case renders the real widget with a real runtime, engine, and worker
/// isolate over synthetic text; nothing here is a rectangle stand-in for the
/// component under test.
void main() {
  late PresentationRuntime runtime;
  late ConversationMarkdownPreparation preparation;

  setUp(() {
    runtime = PresentationRuntime();
    preparation = conversationMarkdownTestPreparation(runtime: runtime);
  });

  tearDown(() {
    unawaited(preparation.dispose());
    runtime.dispose();
  });

  Widget app(Widget child) => conversationMarkdownTestApp(
    preparation: preparation,
    child: child,
  );

  Widget markdown({
    required String data,
    required String identity,
    bool isStreaming = false,
    Color? foreground,
    MessageMarkdownStyle renderStyle = const MessageMarkdownStyle(),
  }) => conversationMarkdownTestView(
    data: data,
    identity: identity,
    isStreaming: isStreaming,
    foreground: foreground,
    renderStyle: renderStyle,
  );

  Future<void> waitFor(
    WidgetTester tester,
    bool Function() ready, {
    String description = 'the expected state',
  }) => waitForConversationMarkdown(
    tester,
    ready,
    description: description,
  );

  Future<void> pumpPrepared(WidgetTester tester, String identity) async {
    await waitForPreparedBody(tester, preparation, identity);
    await tester.pump();
  }

  Future<void> finish(WidgetTester tester) =>
      finishConversationMarkdownTest(tester, preparation, runtime);

  testWidgets('the view shows the prepared blocks instead of the source text', (
    tester,
  ) async {
    const data =
        '# Title\n\nbody **bold** and `code`\n\n'
        '| a | b |\n| --- | --- |\n| 1 | 2 |\n\n';
    await tester.pumpWidget(app(markdown(data: data, identity: 'm1')));
    // The first frame is the calm local loading state: the view renders the
    // text it holds and never parses it on the rendering path.
    expect(find.textContaining('# Title'), findsOneWidget);

    await pumpPrepared(tester, 'm1');
    expect(find.textContaining('# Title'), findsNothing);
    expect(find.text('Title'), findsOneWidget);
    expect(find.byType(Table), findsOneWidget);
    expect(
      preparation.workerFor('m1')?.runsInCallerIsolate,
      isFalse,
      reason: 'the body was prepared on a worker isolate',
    );
    await finish(tester);
  });

  testWidgets('a restyle repaints the same prepared value without re-preparing', (
    tester,
  ) async {
    const data = '# Title\n\nbody text\n\n';
    await tester.pumpWidget(app(markdown(data: data, identity: 'm2')));
    await pumpPrepared(tester, 'm2');
    final prepared = preparation.valueFor('m2');
    expect(prepared, isNotNull);
    final preparations = preparation.preparationsFor('m2');

    // Replacing colours and renderer metrics is a pure appearance change: the
    // business read count must not move.
    await tester.pumpWidget(
      app(
        markdown(
          data: data,
          identity: 'm2',
          foreground: const Color(0xFF00FF00),
          renderStyle: const MessageMarkdownStyle(
            bodyFontSize: 17,
            heading1FontSize: 22,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(identical(preparation.valueFor('m2'), prepared), isTrue);
    expect(preparation.preparationsFor('m2'), preparations);
    expect(find.text('Title'), findsOneWidget);
    expect(
      messageMarkdownSpanFontSize(tester, 'Title'),
      22,
      reason: 'the restyled heading renders from the same prepared block',
    );
    await finish(tester);
  });

  testWidgets('streaming anchors frozen blocks and keeps the tail calm', (
    tester,
  ) async {
    const first = '# Title\n\nintro\n\n';
    await tester.pumpWidget(
      app(markdown(data: first, identity: 'm3', isStreaming: true)),
    );
    await pumpPrepared(tester, 'm3');
    expect(
      find.byKey(const ValueKey<String>('message-markdown-block-block-0')),
      findsOneWidget,
    );
    final firstValue = preparation.valueFor('m3');

    const grown = '# Title\n\nintro\n\nbody grows';
    await tester.pumpWidget(
      app(markdown(data: grown, identity: 'm3', isStreaming: true)),
    );
    await waitFor(
      tester,
      () =>
          preparation.valueFor('m3') != null &&
          !identical(preparation.valueFor('m3'), firstValue),
      description: 'the appended revision',
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('message-markdown-block-block-0')),
      findsOneWidget,
      reason: 'the frozen heading keeps its anchor while the stream grows',
    );
    expect(messageMarkdownSpanFontSize(tester, 'Title'), 18);
    expect(
      messageMarkdownSpanFontSize(tester, 'body grows'),
      14,
      reason: 'the growing tail renders in the calm body presentation',
    );
    await finish(tester);
  });

  testWidgets('a streaming message notifies only its own subscriber', (
    tester,
  ) async {
    final siblingEvents = <ConversationMarkdownBodyState>[];
    final releaseSibling = preparation.watch('m5', siblingEvents.add);
    addTearDown(releaseSibling);
    await tester.pumpWidget(
      app(
        Column(
          children: [
            markdown(data: 'first body\n\n', identity: 'm4', isStreaming: true),
            markdown(data: 'sibling body\n\n', identity: 'm5'),
          ],
        ),
      ),
    );
    await pumpPrepared(tester, 'm4');
    await pumpPrepared(tester, 'm5');
    final siblingPreparations = preparation.preparationsFor('m5');
    final siblingValue = preparation.valueFor('m5');
    siblingEvents.clear();

    for (var index = 0; index < 4; index++) {
      final data = 'first body\n\nstep $index\n\n';
      final previous = preparation.valueFor('m4');
      await tester.pumpWidget(
        app(
          Column(
            children: [
              markdown(data: data, identity: 'm4', isStreaming: true),
              markdown(data: 'sibling body\n\n', identity: 'm5'),
            ],
          ),
        ),
      );
      await waitFor(
        tester,
        () =>
            preparation.valueFor('m4') != null &&
            !identical(preparation.valueFor('m4'), previous),
        description: 'revision $index of the streaming message',
      );
    }

    expect(preparation.preparationsFor('m5'), siblingPreparations);
    expect(identical(preparation.valueFor('m5'), siblingValue), isTrue);
    expect(siblingEvents, isEmpty, reason: 'no sibling install or withdrawal');
    expect(preparation.preparationsFor('m4'), greaterThan(1));
    await finish(tester);
  });

  testWidgets('the real message block prepares its body and answers a click', (
    tester,
  ) async {
    final adapter = AgentRenderAdapter.fallback();
    const data = '''# Answer

Visible **body** text.

<recommended_plugins>
- Plugin One
- Plugin Two
</recommended_plugins>

<ADDITIONAL_METADATA>
Hidden detail value
</ADDITIONAL_METADATA>''';

    await tester.pumpWidget(
      app(
        Builder(
          builder: (context) {
            final colors = context.licoColors;
            return AgentConversationMessageContent(
              data: data,
              foreground: colors.text,
              accent: colors.primary,
              codeBackground: colors.surfaceRaised,
              blockBackground: colors.surface,
              borderColor: colors.line,
              renderStyle: adapter.markdownStyle,
            );
          },
        ),
      ),
    );
    // The body goes through the prepared pipeline even though this call site
    // does not know the message identity yet: the view prepares its own text.
    await waitFor(
      tester,
      () => preparation.registry.sources.any(
        (source) =>
            !source.retired &&
            preparation.valueFor(source.current.identity) != null,
      ),
      description: 'the prepared message body',
    );
    await tester.pump();

    expect(find.textContaining('# Answer'), findsNothing);
    expect(find.text('Answer'), findsOneWidget);
    expect(find.text('Recommended Plugins · 2'), findsOneWidget);
    expect(find.text('Details'), findsOneWidget);
    expect(
      find.textContaining('Hidden detail value', findRichText: true),
      findsNothing,
    );

    await tester.tap(find.text('Details'));
    await tester.pumpAndSettle();
    await waitFor(
      tester,
      () => preparation.registry.sources.any(
        (source) =>
            !source.retired &&
            preparation.valueFor(source.current.identity) != null,
      ),
      description: 'the prepared details body',
    );
    await tester.pump();
    expect(
      find.textContaining('Hidden detail value', findRichText: true),
      findsOneWidget,
    );

    await tester.tap(find.text('Recommended Plugins · 2'));
    await tester.pumpAndSettle();
    await waitFor(
      tester,
      () => preparation.registry.sources.any(
        (source) =>
            !source.retired &&
            preparation.valueFor(source.current.identity) != null,
      ),
      description: 'the prepared plugin list',
    );
    await tester.pump();
    expect(
      find.textContaining('Plugin One', findRichText: true),
      findsOneWidget,
    );
    await finish(tester);
  });

  testWidgets(
    'an authority withdrawal hides displayed content and never auto-recovers',
    (tester) async {
      const data = '# Title\n\nbody text\n\n';
      await tester.pumpWidget(app(markdown(data: data, identity: 'w1')));
      await pumpPrepared(tester, 'w1');
      expect(find.text('Title'), findsOneWidget);
      final preparations = preparation.preparationsFor('w1');

      // The application withdraws authority over this body while the view still
      // holds the old text.
      runtime.revoke(conversationMarkdownFieldGroupFor('w1').resource);
      await waitFor(
        tester,
        () => preparation.stateFor('w1') is ConversationMarkdownWithdrawn,
        description: 'the withdrawal to reach the view',
      );
      await tester.pump();
      expect(
        preparation.stateFor('w1'),
        isA<ConversationMarkdownWithdrawn>().having(
          (state) => state.reason,
          'reason',
          ConversationMarkdownWithdrawal.revoked,
        ),
      );
      expect(find.text('Title'), findsNothing, reason: 'the prepared value hides');
      expect(
        find.textContaining('# Title'),
        findsNothing,
        reason: 'the fallback must not resurrect withdrawn content',
      );

      // A same-props rebuild and a restyle are not a new read.
      await tester.pumpWidget(
        app(
          markdown(
            data: data,
            identity: 'w1',
            foreground: const Color(0xFF00FF00),
            renderStyle: const MessageMarkdownStyle(bodyFontSize: 17),
          ),
        ),
      );
      await tester.pump();
      expect(find.textContaining('# Title'), findsNothing);
      expect(find.text('Title'), findsNothing);
      expect(
        preparation.preparationsFor('w1'),
        preparations,
        reason: 'no re-entry from a restyle of the same input',
      );

      // Only a controlled new revision opens a fresh incarnation.
      const next = '# Next\n\nsecond revision\n\n';
      await tester.pumpWidget(app(markdown(data: next, identity: 'w1')));
      await waitFor(
        tester,
        () => preparation.valueFor('w1') != null,
        description: 'the fresh incarnation to install',
      );
      await tester.pump();
      expect(find.text('Next'), findsOneWidget);
      expect(find.textContaining('# Next'), findsNothing);
      await finish(tester);
    },
  );

  testWidgets(
    'a cache retire keeps the loading text and does not re-prepare on a restyle',
    (tester) async {
      const data = '# Title\n\nbody text\n\n';
      await tester.pumpWidget(app(markdown(data: data, identity: 'r1')));
      await pumpPrepared(tester, 'r1');
      expect(find.text('Title'), findsOneWidget);
      final preparations = preparation.preparationsFor('r1');

      // A bounded-retention retire drops the prepared value; the input text is
      // still the conversation's own read.
      preparation.retire('r1');
      await tester.pump();
      expect(
        preparation.stateFor('r1'),
        isA<ConversationMarkdownWithdrawn>().having(
          (state) => state.reason,
          'reason',
          ConversationMarkdownWithdrawal.retired,
        ),
      );
      expect(find.text('Title'), findsNothing, reason: 'the value is dropped');
      expect(
        find.textContaining('# Title'),
        findsOneWidget,
        reason: 'the legitimate local loading text stays',
      );

      await tester.pumpWidget(
        app(
          markdown(
            data: data,
            identity: 'r1',
            foreground: const Color(0xFF00FF00),
          ),
        ),
      );
      await tester.pump();
      expect(
        preparation.preparationsFor('r1'),
        preparations,
        reason: 'a restyle does not re-enter preparation',
      );

      const next = '# Next\n\nfresh read\n\n';
      await tester.pumpWidget(app(markdown(data: next, identity: 'r1')));
      await waitFor(
        tester,
        () => preparation.valueFor('r1') != null,
        description: 'the fresh revision to install',
      );
      await tester.pump();
      expect(find.text('Next'), findsOneWidget);
      await finish(tester);
    },
  );

  testWidgets('an unwired container keeps the view on its own text', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildLicoTheme(platformBrightness: Brightness.dark),
          home: Scaffold(
            body: markdown(data: '# Title\n\nbody\n\n', identity: 'm7'),
          ),
        ),
      ),
    );
    await tester.pump();
    // The port is disabled until composition binds the owner: no preparation
    // runs and the view never parses on the rendering path.
    expect(find.textContaining('# Title'), findsOneWidget);
    expect(find.text('Title'), findsNothing);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  testWidgets('a view outside a presentation container renders its text unparsed', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: markdown(data: '# Title\n\nbody\n\n', identity: 'm6'),
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('# Title'), findsOneWidget);
    expect(find.text('Title'), findsNothing);
    expect(tester.takeException(), isNull);
    unawaited(preparation.dispose());
    runtime.dispose();
  });
}

