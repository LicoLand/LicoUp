// Golden evidence for the collaboration flowchart: the v2 head state (Index
// waits on an escalated gate, Interface carries the Assistant-approved chip,
// Bench is running) under both built-in presets, plus the held-proposal state
// under the dark preset. Synthetic fixture data only.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/contracts/collaboration_run_models.dart';
import 'package:licoup/src/frontend/features/collaboration/ui/collaboration_flowchart_view.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/collaboration/collaboration_binding.dart';
import 'package:licoup/src/projections/collaboration/collaboration_presentation_source.dart';

import '../support/bundled_font_loader.dart';
import 'support/collaboration_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadBundledVisualFonts);

  Future<void> pumpGolden(
    WidgetTester tester, {
    required String presetId,
    required Brightness brightness,
    required CollaborationRunSnapshot snapshot,
  }) async {
    final port = FakeCollaborationRunPort();
    final source = CollaborationPresentationSource(
      port: port,
      conversationId: 'conv-1',
    );
    final binding = CollaborationBinding(
      projection: source,
      intents: source,
      effects: source,
    );
    addTearDown(source.dispose);
    addTearDown(port.close);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1440, 900);
    addTearDown(tester.view.reset);
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
          presetId: presetId,
          platformBrightness: brightness,
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: RepaintBoundary(
          key: const Key('collab-golden-boundary'),
          child: Scaffold(body: CollaborationFlowchartView(binding: binding)),
        ),
      ),
    );
    port.emit(snapshot);
    await tester.pump();
    await tester.pump();
    // Fit the whole graph so the golden covers every card.
    await tester.tap(find.byTooltip('适应'));
    await tester.pump();
  }

  testWidgets('flowchart renders the v2 head under the light preset', (
    tester,
  ) async {
    await pumpGolden(
      tester,
      presetId: AppearancePresetIds.taroWaffle,
      brightness: Brightness.light,
      snapshot: collabSnapshotV2(),
    );
    await expectLater(
      find.byKey(const Key('collab-golden-boundary')),
      matchesGoldenFile('../goldens/collaboration/flowchart_light.png'),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('flowchart renders the v2 head under the dark preset', (
    tester,
  ) async {
    await pumpGolden(
      tester,
      presetId: AppearancePresetIds.starlitGold,
      brightness: Brightness.dark,
      snapshot: collabSnapshotV2(),
    );
    await expectLater(
      find.byKey(const Key('collab-golden-boundary')),
      matchesGoldenFile('../goldens/collaboration/flowchart_dark.png'),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('flowchart renders a held proposal under the dark preset', (
    tester,
  ) async {
    await pumpGolden(
      tester,
      presetId: AppearancePresetIds.starlitGold,
      brightness: Brightness.dark,
      snapshot: collabSnapshotWithProposal(),
    );
    await expectLater(
      find.byKey(const Key('collab-golden-boundary')),
      matchesGoldenFile('../goldens/collaboration/proposal_dark.png'),
    );
    await tester.pumpWidget(const SizedBox());
  });
}
