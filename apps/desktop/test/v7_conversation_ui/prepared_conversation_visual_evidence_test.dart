import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_runtime/presentation_runtime.dart';

import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_message_blocks.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_render_adapter.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/message_markdown.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/conversation/conversation_markdown_port.dart';
import 'package:licoup/src/projections/conversation/conversation_markdown_preparation.dart';

import '../support/bundled_font_loader.dart';
import 'prepared_message_markdown_harness.dart';

/// Renders the real conversation message component from prepared values and
/// writes a synthetic PNG when an evidence directory is configured.
///
/// This is the local rendering mechanism, not a rectangle stand-in: the scene
/// mounts the production message block, the production theme, and the real
/// preparation pipeline over synthetic text. Set
/// `LICO_CONVERSATION_MARKDOWN_EVIDENCE_DIR` to capture the frames.
///
/// Frame scope actually measured here: the prepared steady state, the first
/// frame of a fresh stream, and eight concurrent streaming bodies. Not
/// measured: production frame/raster/input timing, IME composition, and
/// scroll-anchor behaviour under a real pointer; those stay for the
/// production-profile acceptance.
void main() {
  const evidenceDirectory = String.fromEnvironment(
    'LICO_CONVERSATION_MARKDOWN_EVIDENCE_DIR',
  );
  const body = '''# 合成回复标题

正文包含 **加粗**、`代码` 和 [链接](https://example.test)。

- 第一项
- 第二项

| 列 A | 列 B |
| --- | --- |
| 值 1 | 值 2 |

```dart
final prepared = await engine.decompose(...);
```

> 引用一行

<ADDITIONAL_METADATA>
隐藏的合成细节
</ADDITIONAL_METADATA>''';

  for (final scene in [
    (
      name: 'conversation-markdown-desktop-dark',
      size: const Size(900, 760),
      scale: 1.0,
      brightness: Brightness.dark,
    ),
    (
      name: 'conversation-markdown-narrow-light',
      size: const Size(360, 780),
      scale: 2.0,
      brightness: Brightness.light,
    ),
  ]) {
    testWidgets('synthetic prepared conversation render ${scene.name}', (
      tester,
    ) async {
      tester.view.physicalSize = scene.size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await loadBundledVisualFonts();
      // The code block names the host's `SF Mono`. A synthetic scene may not
      // read host fonts, so the bundled mono face stands in for it and the
      // frame shows real code glyphs instead of the test placeholder face.
      final monoSubstitute = FontLoader('SF Mono')
        ..addFont(rootBundle.load('assets/fonts/GeistMono-Regular.ttf'));
      await monoSubstitute.load();

      final runtime = PresentationRuntime();
      final preparation = ConversationMarkdownPreparation(
        runtime: runtime,
        engineFactory: _spawnEngine,
      );
      addTearDown(() {
        unawaited(preparation.dispose());
        runtime.dispose();
      });

      final adapter = AgentRenderAdapter.fallback();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            conversationMarkdownPortProvider.overrideWithValue(preparation),
          ],
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            locale: const Locale('zh'),
            supportedLocales: LicoStrings.supportedLocales,
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
            ],
            theme: buildLicoTheme(platformBrightness: scene.brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scene.scale),
                disableAnimations: true,
              ),
              child: child!,
            ),
            home: RepaintBoundary(
              key: const Key('conversation-markdown-visual'),
              child: Scaffold(
                body: Padding(
                  padding: EdgeInsets.all(scene.scale == 1 ? 20 : 8),
                  child: Builder(
                    builder: (context) {
                      final colors = context.licoColors;
                      return SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            AgentConversationMessageContent(
                              data: body,
                              foreground: colors.text,
                              accent: colors.primary,
                              codeBackground: colors.surfaceRaised,
                              blockBackground: colors.surface,
                              borderColor: colors.line,
                              renderStyle: adapter.markdownStyle,
                            ),
                            const SizedBox(height: 12),
                            // Eight concurrent streaming bodies: the narrow
                            // subscriptions each keep their own prepared value.
                            for (var index = 0; index < 8; index++)
                              _StreamingSample(
                                key: ValueKey<int>(index),
                                index: index,
                                colors: colors,
                                renderStyle: adapter.markdownStyle,
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await _waitForPrepared(tester, preparation);
      await tester.pump();

      expect(find.text('合成回复标题'), findsOneWidget);
      expect(find.textContaining('# 合成回复标题'), findsNothing);
      expect(find.text('隐藏的合成细节'), findsNothing);
      expect(tester.takeException(), isNull);

      if (evidenceDirectory.isNotEmpty) {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const Key('conversation-markdown-visual')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final directory = Directory(evidenceDirectory);
          directory.createSync(recursive: true);
          File(
            '${directory.path}/${scene.name}.png',
          ).writeAsBytesSync(bytes!.buffer.asUint8List());
        });
      }

      await finishConversationMarkdownTest(tester, preparation, runtime);
    });
  }
}

final class _StreamingSample extends StatelessWidget {
  const _StreamingSample({
    super.key,
    required this.index,
    required this.colors,
    required this.renderStyle,
  });

  final int index;
  final LicoThemeColors colors;
  final MessageMarkdownStyle renderStyle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: MessageMarkdown(
        data: '### 流式样例 $index\n\n正在生成第 $index 段内容',
        identity: 'visual-stream-$index',
        isStreaming: true,
        foreground: colors.text,
        accent: colors.primary,
        codeBackground: colors.surfaceRaised,
        blockBackground: colors.surface,
        borderColor: colors.line,
        renderStyle: renderStyle,
      ),
    );
  }
}

Future<void> _waitForPrepared(
  WidgetTester tester,
  ConversationMarkdownPreparation preparation, {
  int frames = 600,
}) async {
  for (var frame = 0; frame < frames; frame++) {
    final ready =
        preparation.registry.sources.isNotEmpty &&
        preparation.registry.sources.every(
          (source) =>
              source.retired ||
              preparation.valueFor(source.current.identity) != null,
        );
    if (ready) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 5));
  }
  fail('the prepared conversation render did not settle');
}

Future<MarkdownPreparationEngine> _spawnEngine() async {
  final pool = await PreparationWorkerPool.spawn(
    name: 'conversation-markdown-visual-test',
    operations: MarkdownPreparationEngine.workerOperations,
    workers: 2,
  );
  return MarkdownPreparationEngine(
    workers: pool,
    cache: MarkdownPreparationCache(),
  );
}
