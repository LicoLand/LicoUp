import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/frontend/features/agents/ui/execution_process/conversation_execution_viewer.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

import '../support/bundled_font_loader.dart';

void main() {
  const evidenceDirectory = String.fromEnvironment(
    'LICO_EXECUTION_EVIDENCE_DIR',
  );
  for (final scene in [
    (
      name: 'execution-process-desktop-dark',
      size: const Size(1100, 800),
      scale: 1.0,
      brightness: Brightness.dark,
    ),
    (
      name: 'execution-process-narrow-200-light',
      size: const Size(340, 780),
      scale: 2.0,
      brightness: Brightness.light,
    ),
  ]) {
    testWidgets('synthetic visual acceptance ${scene.name}', (tester) async {
      tester.view.physicalSize = scene.size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await loadBundledVisualFonts();
      final source = ValueNotifier(
        const ConversationExecutionSnapshot(
          records: [
            ConversationExecutionRecord(
              id: 'thinking',
              kind: 'reasoning.delta',
              timestamp: '2026-01-01T09:00:01Z',
              rawText:
                  '{\n'
                  '  "type": "reasoning.delta",\n'
                  '  "text": "先检查输入，再验证工具结果。",\n'
                  '  "unknown_metadata": {"origin": "synthetic fixture"}\n'
                  '}',
            ),
            ConversationExecutionRecord(
              id: 'tool',
              kind: 'tool.call',
              timestamp: '2026-01-01T09:00:02Z',
              rawText:
                  '{\n'
                  '  "type": "tool.call",\n'
                  '  "name": "inspect_fixture",\n'
                  '  "arguments": {"sample": "demo", "include_details": true},\n'
                  '  "call_id": "fixture-call-01"\n'
                  '}',
            ),
            ConversationExecutionRecord(
              id: 'output',
              kind: 'tool.output',
              timestamp: '2026-01-01T09:00:03Z',
              rawText:
                  '{\n'
                  '  "type": "tool.output",\n'
                  '  "call_id": "fixture-call-01",\n'
                  '  "output": "已验证 3 个合成样例。\\n状态：完成。",\n'
                  '  "unknown_metadata": {"trace": ["read", "verify", "done"]}\n'
                  '}',
            ),
          ],
        ),
      );
      addTearDown(source.dispose);
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          locale: const Locale('zh'),
          supportedLocales: LicoStrings.supportedLocales,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          theme: buildLicoTheme(
            presetId: scene.brightness == Brightness.light
                ? AppearancePresetIds.licoSodaLight
                : AppearancePresetIds.licoSoda,
            platformBrightness: scene.brightness,
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scene.scale),
              disableAnimations: true,
            ),
            child: child!,
          ),
          home: RepaintBoundary(
            key: const Key('execution-process-visual'),
            child: Scaffold(
              body: Padding(
                padding: EdgeInsets.all(scene.scale == 1 ? 22 : 8),
                child: ConversationExecutionViewer(
                  source: source,
                  agentIcon: const Icon(Icons.smart_toy_outlined),
                  agentName: 'Fixture Agent',
                  conversationTitle: '合成执行样例',
                  onCopyText: (_) async {},
                  onClose: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('execution-process-search')),
        'unknown_metadata',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(find.text('1 / 2'), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (evidenceDirectory.isNotEmpty) {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const Key('execution-process-visual')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final directory = Directory(evidenceDirectory);
          directory.createSync(recursive: true);
          File(
            '${directory.path}/${scene.name}.png',
          ).writeAsBytesSync(bytes!.buffer.asUint8List());
          image.dispose();
        });
        await tester.pump();
      }
    });
  }
}
