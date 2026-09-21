import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/presentation_runtime.dart';

import 'package:licoup/src/frontend/shared/ui/message_markdown.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/conversation/conversation_markdown_port.dart';
import 'package:licoup/src/projections/conversation/conversation_markdown_preparation.dart';

/// Reusable component-integration harness for prepared message markdown.
///
/// A widget test that renders message content needs three things this file
/// provides: a container that installs a real preparation pipeline, a wait that
/// lets the worker isolates settle while frames keep pumping, and a drain that
/// stops the pool before the binding checks for pending timers.

/// The real projection-layer preparation over the real runtime, engine, and
/// worker isolates: tests bind it through the port exactly as composition does.
ConversationMarkdownPreparation conversationMarkdownTestPreparation({
  PresentationRuntime? runtime,
  int workers = 2,
}) => ConversationMarkdownPreparation(
  runtime: runtime ?? PresentationRuntime(),
  engineFactory: () async {
    final pool = await PreparationWorkerPool.spawn(
      name: 'conversation-markdown-test',
      operations: MarkdownPreparationEngine.workerOperations,
      workers: workers,
    );
    return MarkdownPreparationEngine(
      workers: pool,
      cache: MarkdownPreparationCache(),
    );
  },
);

/// A Material app whose container installs [preparation].
Widget conversationMarkdownTestApp({
  required ConversationMarkdownPreparation preparation,
  required Widget child,
  Brightness brightness = Brightness.dark,
}) => ProviderScope(
  overrides: [
    conversationMarkdownPortProvider.overrideWithValue(preparation),
  ],
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildLicoTheme(platformBrightness: brightness),
    home: Scaffold(body: child),
  ),
);

/// A markdown view wired to the surrounding container.
Widget conversationMarkdownTestView({
  required String data,
  required String identity,
  bool isStreaming = false,
  Color? foreground,
  MessageMarkdownStyle renderStyle = const MessageMarkdownStyle(),
}) => Builder(
  builder: (context) {
    final colors = context.licoColors;
    return MessageMarkdown(
      data: data,
      identity: identity,
      isStreaming: isStreaming,
      foreground: foreground ?? colors.text,
      accent: colors.primary,
      codeBackground: colors.surfaceRaised,
      blockBackground: colors.surface,
      borderColor: colors.line,
      renderStyle: renderStyle,
    );
  },
);

/// Lets worker isolates settle while the binding keeps pumping frames.
Future<void> waitForConversationMarkdown(
  WidgetTester tester,
  bool Function() ready, {
  String description = 'the expected state',
  int frames = 600,
}) async {
  for (var frame = 0; frame < frames; frame++) {
    if (ready()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 5));
  }
  fail('$description did not arrive');
}

/// Waits until [identity] has an installed prepared value.
Future<void> waitForPreparedBody(
  WidgetTester tester,
  ConversationMarkdownPreparation preparation,
  String identity, {
  PreparedValue<MessageMarkdownBlock>? differentFrom,
}) => waitForConversationMarkdown(
  tester,
  () {
    final value = preparation.valueFor(identity);
    return value != null && !identical(value, differentFrom);
  },
  description: 'a prepared value for $identity',
);

/// Releases the pipeline and drains its workers inside the test body.
///
/// The binding refuses to end a test with pending timers. The pool's shutdown
/// handshake completes through the test's zone, so the drain alternates real
/// asynchronous waits with frames instead of only advancing fake time.
Future<void> finishConversationMarkdownTest(
  WidgetTester tester,
  ConversationMarkdownPreparation preparation,
  PresentationRuntime runtime,
) async {
  await tester.pump();
  unawaited(preparation.dispose());
  for (var frame = 0; frame < 60; frame++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 10));
  }
  runtime.dispose();
  await tester.pump(const Duration(milliseconds: 100));
}

/// The font size a rich markdown span actually renders with.
double? messageMarkdownSpanFontSize(WidgetTester tester, String text) {
  final widget = tester.widget<Text>(find.text(text));
  final span = widget.textSpan;
  if (span is! TextSpan) return widget.style?.fontSize;
  final children = span.children;
  if (children != null && children.isNotEmpty && children.first is TextSpan) {
    return (children.first as TextSpan).style?.fontSize ?? span.style?.fontSize;
  }
  return span.style?.fontSize;
}
