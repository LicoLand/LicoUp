import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_flutter/presentation_flutter.dart';
import 'package:presentation_runtime/presentation_runtime.dart';

import 'package:licoup/src/composition/extensions/extension_ui_composition.dart';
import 'package:licoup/src/composition/extensions/project_collaboration_session.dart';
import 'package:licoup/src/frontend/features/project_collaboration/ui/project_collaboration_page.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/projections/project_collaboration/project_collaboration_source.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/frontend/appearance/appearance_preset_config.dart';

import '../support/bundled_font_loader.dart';
import 'project_collaboration_scenario.dart';

/// Renders the real project collaboration surface and writes synthetic PNGs
/// when an evidence directory is configured.
///
/// This is the local rendering mechanism, not a rectangle stand-in: the scenes
/// mount the production page and the production graph view over the production
/// theme, localization and preparation pipeline with synthetic data. The
/// fixture is deliberately a small, readable project set for review; it is not
/// the frozen performance scale (8 projects / 1000 units / 2000 edges), and
/// nothing here measures frames.
///
/// Set `LICO_PROJECT_COLLABORATION_EVIDENCE_DIR` to capture the frames.
void main() {
  const evidenceDirectory = String.fromEnvironment(
    'LICO_PROJECT_COLLABORATION_EVIDENCE_DIR',
  );
  final captures = <String, Uint8List>{};

  /// A small review fixture: three projects, one shared gate, one blocked unit
  /// and one healthy running unit.
  GraphResourceValue reviewDocument({int planRevision = 1}) =>
      GraphResourceValue.fromJson(
        threeProjectDocumentJson(planRevision: planRevision),
      );

  Future<void> capture(WidgetTester tester, String name) async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const Key('project-collaboration-evidence')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final pixels = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      captures[name] = Uint8List.fromList(pixels!.buffer.asUint8List());
      if (evidenceDirectory.isEmpty) {
        image.dispose();
        return;
      }
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final directory = Directory(evidenceDirectory);
      directory.createSync(recursive: true);
      File(
        '${directory.path}/$name-after.png',
      ).writeAsBytesSync(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  /// Mounts one scene in the real theme and language.
  Future<void> pumpScene(
    WidgetTester tester, {
    required ProjectCollaborationSession session,
    required Size size,
    required Brightness brightness,
    String languageCode = 'zh',
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('project-collaboration-evidence'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          locale: Locale(languageCode),
          supportedLocales: LicoStrings.supportedLocales,
          localizationsDelegates: const <LocalizationsDelegate<Object>>[
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          theme: buildLicoTheme(
            presetId: appearancePresetIdForBrightness(
              brightness == Brightness.dark,
            ),
            platformBrightness: brightness,
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: Scaffold(body: ProjectCollaborationPage(surface: session)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      Theme.of(
        tester.element(find.byType(ProjectCollaborationPage)),
      ).brightness,
      brightness,
      reason: 'the resolved product preset must match the evidence label',
    );
    for (final badge in find.byType(StatusBadge).evaluate()) {
      final text = tester.widget<Text>(
        find.descendant(
          of: find.byWidget(badge.widget),
          matching: find.byType(Text),
        ),
      );
      final box = tester.widget<Container>(
        find
            .descendant(
              of: find.byWidget(badge.widget),
              matching: find.byType(Container),
            )
            .first,
      );
      final foreground = text.style!.color!.computeLuminance();
      final background = (box.decoration! as BoxDecoration).color!
          .computeLuminance();
      final ratio =
          ((foreground > background ? foreground : background) + .05) /
          ((foreground < background ? foreground : background) + .05);
      expect(
        ratio,
        greaterThanOrEqualTo(4.5),
        reason: 'computed chip text/surface contrast, not root theme contrast',
      );
    }
  }

  Future<void> untilPrepared(
    WidgetTester tester,
    ProjectCollaborationSession session,
  ) async {
    for (var attempt = 0; attempt < 600; attempt++) {
      if (session.current != null) {
        await tester.pumpAndSettle();
        return;
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }
    throw StateError('the review fixture never prepared');
  }

  Future<void> finish(
    WidgetTester tester,
    ProjectCollaborationSession session,
    ExtensionUiComposition composition,
  ) async {
    session.dispose();
    unawaited(composition.dispose());
    for (var frame = 0; frame < 60; frame++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  }

  testWidgets('synthetic project collaboration render', (tester) async {
    await loadBundledVisualFonts();
    final runtime = PresentationRuntime();
    final composition = ExtensionUiComposition(runtime: runtime);
    final owner = SyntheticProjectCollaborationOwner(currentRevision: () => 1);
    final session = ProjectCollaborationSession(
      runtime: runtime,
      source: ProjectCollaborationDocumentSource()..seed(reviewDocument()),
      owner: owner,
    )..start();
    addTearDown(() {
      unawaited(composition.dispose());
      runtime.dispose();
    });

    // The prepared board in the wide dark surface.
    await pumpScene(
      tester,
      session: session,
      size: const Size(1280, 900),
      brightness: Brightness.dark,
    );
    await untilPrepared(tester, session);
    expect(find.text('alpha-build'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await capture(tester, 'board-wide-dark-zh');

    // The same board in the light surface and in English.
    await pumpScene(
      tester,
      session: session,
      size: const Size(1280, 900),
      brightness: Brightness.light,
      languageCode: 'en',
    );
    await untilPrepared(tester, session);
    await capture(tester, 'board-wide-light-en');

    // A selected unit with its reason and actions.
    await tester.tap(
      find.byKey(
        const Key('project-collaboration-node-licoup.node/alpha-review'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Why it cannot start'), findsOneWidget);
    await capture(tester, 'detail-selected-light-en');

    // The insert preview with its impact and the version a commit cites.
    await tester.tap(find.byKey(const Key('project-collaboration-insert')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('project-collaboration-insert-unit-ref')),
      'unit/alpha-extra',
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find
          .byKey(const Key('project-collaboration-insert-preview'))
          .hitTestable(),
    );
    await tester.pumpAndSettle();
    expect(find.text('Previewed impact'), findsOneWidget);
    await capture(tester, 'insert-preview-light-en');
    final plain = captures['detail-selected-light-en']!;
    final modal = captures['insert-preview-light-en']!;
    expect(modal.length, plain.length);
    var changedPixels = 0;
    for (var pixel = 0; pixel < modal.length; pixel += 4) {
      if ((modal[pixel] - plain[pixel]).abs() > 10 ||
          (modal[pixel + 1] - plain[pixel + 1]).abs() > 10 ||
          (modal[pixel + 2] - plain[pixel + 2]).abs() > 10) {
        changedPixels++;
      }
    }
    expect(
      changedPixels / (modal.length / 4),
      greaterThan(.1),
      reason: 'dialog and modal barrier must exist in captured pixels',
    );
    await tester.tap(
      find.byKey(const Key('project-collaboration-insert-commit-cancel')),
    );
    await tester.pumpAndSettle();

    // The narrow surface with the detail panel called out.
    await pumpScene(
      tester,
      session: session,
      size: const Size(430, 900),
      brightness: Brightness.dark,
    );
    await untilPrepared(tester, session);
    // Start from a closed panel so the callout is the scene, not a leftover.
    if (find
        .byKey(const Key('project-collaboration-detail-panel'))
        .evaluate()
        .isNotEmpty) {
      await tester.tap(
        find.byKey(const Key('project-collaboration-close-detail')),
      );
      await tester.pumpAndSettle();
    }
    expect(
      find.byKey(const Key('project-collaboration-detail-panel')),
      findsNothing,
    );
    await capture(tester, 'board-narrow-dark-zh');
    for (final control in [
      'open-projects',
      'open-detail',
      'filter-all',
      'filter-frontier',
      'filter-anomalies',
      'zoom-reset',
    ]) {
      expect(
        find.byKey(Key('project-collaboration-$control')).hitTestable(),
        findsOneWidget,
        reason: '$control must be reachable without overlap',
      );
    }
    await tester.tap(
      find.byKey(const Key('project-collaboration-open-detail')),
      warnIfMissed: true,
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('project-collaboration-detail-panel')),
      findsOneWidget,
      reason: 'the narrow detail callout is the scene',
    );
    await capture(tester, 'detail-narrow-dark-zh');

    await finish(tester, session, composition);

    // A withdrawn source on the wide surface: the calm unavailable state, named
    // in words instead of a reason code.
    final revokedRuntime = PresentationRuntime();
    final revokedComposition = ExtensionUiComposition(runtime: revokedRuntime);
    final revokedSession = ProjectCollaborationSession(
      runtime: revokedRuntime,
      source: ProjectCollaborationDocumentSource()..seed(reviewDocument()),
      owner: owner,
    )..start();
    await pumpScene(
      tester,
      session: revokedSession,
      size: const Size(1280, 900),
      brightness: Brightness.dark,
    );
    await untilPrepared(tester, revokedSession);
    revokedRuntime.revoke(revokedSession.source.fieldGroup.resource);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('project-collaboration-unavailable')),
      findsOneWidget,
    );
    expect(find.text('项目来源已不可用'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('project-collaboration-insert')),
          )
          .onPressed,
      isNull,
    );
    await capture(tester, 'unavailable-wide-dark-zh');
    await finish(tester, revokedSession, revokedComposition);
  });
}
