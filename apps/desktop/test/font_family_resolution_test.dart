import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/app.dart';
import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/composition/client_app_composition.dart';
import 'package:licoup/src/frontend/shared/ui/lico_typography.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';

/// The two claims the font baseline makes, driven through the production app:
///
/// - a first launch — no preference, nothing installed, offline — renders the
///   platform's own family and loads no bundled font;
/// - the appearance font preference reaches the type scale, so changing it
///   changes the family the interface renders with.
void main() {
  late Directory dataRoot;

  setUp(() {
    dataRoot = Directory.systemTemp.createTempSync('licoup-font-baseline-');
  });

  tearDown(() {
    if (dataRoot.existsSync()) dataRoot.deleteSync(recursive: true);
  });

  testWidgets(
    'a first launch renders the platform family and loads no bundled font',
    (tester) async {
      // The desktop client ships on macOS; the platform family is part of the
      // claim, so the platform is pinned instead of following the test host.
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final controller = ClientController(
        portableData: PortableDataRoot(dataDirectoryOverride: dataRoot),
      );
      final composition = ClientAppComposition(controller: controller);
      try {
        await tester.pumpWidget(
          LicoApp(
            compositionFactory: () => composition,
            initializeController: false,
            homeBuilder: (_, _, _) => const SizedBox(),
          ),
        );
        await tester.pump();

        final platformFamily = LicoTypography.sansFamilyFor(
          TargetPlatform.macOS,
        );
        final theme = tester
            .widget<MaterialApp>(find.byType(MaterialApp))
            .theme!;
        final body = theme.textTheme.bodyLarge!;

        expect(
          body.fontFamily,
          platformFamily,
          reason: 'a first launch must render the operating system family',
        );
        expect(
          body.fontFamily,
          isNot(LicoTypography.bundledSansFamily),
          reason: 'no bundled face may be required to render the interface',
        );
        expect(body.fontFamilyFallback!.first, platformFamily);
        expect(
          body.fontFamilyFallback,
          isNot(contains('Noto Sans SC')),
          reason: 'the removed bundled CJK font must not be a fallback',
        );

        // The removed asset is neither declared nor on disk, so nothing can load
        // it: the bundle is what the packaged client installs.
        final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
        expect(
          manifest.listAssets().where(
            (asset) => asset.toLowerCase().contains('notosanssc'),
          ),
          isEmpty,
          reason: 'the font bundle must no longer declare a CJK font',
        );
        expect(
          File('assets/fonts/NotoSansSC.ttf').existsSync(),
          isFalse,
          reason: 'the 17.7 MB CJK font must be gone from the client tree',
        );
      } finally {
        await tester.runAsync(composition.dispose);
        controller.dispose();
        await tester.pumpWidget(const SizedBox());
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets('changing the font preference changes the rendered family', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final controller = ClientController(
      portableData: PortableDataRoot(dataDirectoryOverride: dataRoot),
    );
    final composition = ClientAppComposition(controller: controller);
    try {
      await tester.pumpWidget(
        LicoApp(
          compositionFactory: () => composition,
          initializeController: false,
          // Material supplies the theme's own body style; without it the
          // framework's debug default style would be what renders.
          homeBuilder: (_, _, _) => Builder(
            builder: (context) =>
                const Material(child: Text('probe', key: Key('probe'))),
          ),
        ),
      );
      await tester.pump();

      final platformFamily = LicoTypography.sansFamilyFor(TargetPlatform.macOS);
      String renderedFamily() => tester
          .renderObject<RenderParagraph>(find.byKey(const Key('probe')))
          .text
          .style!
          .fontFamily!;

      expect(renderedFamily(), platformFamily);

      // Changing the preference is what changes the interface: no rebuild of the
      // preset, no restart, only the projection's font preference.
      controller.appearancePreferenceOwner.replaceFontPreference(
        LicoTypography.bundledSansFamily,
      );
      // One frame rebuilds the theme; the inherited body style settles on the
      // next one, because Material animates its default text style.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final theme = tester.widget<MaterialApp>(find.byType(MaterialApp)).theme!;
      expect(
        theme.textTheme.bodyLarge!.fontFamily,
        LicoTypography.bundledSansFamily,
      );
      expect(renderedFamily(), LicoTypography.bundledSansFamily);
      expect(
        renderedFamily(),
        isNot(platformFamily),
        reason: 'the preference must override the platform baseline',
      );
      expect(
        theme.textTheme.bodyLarge!.fontFamilyFallback,
        contains(platformFamily),
        reason: 'a preferred family keeps the platform chain behind it',
      );

      // Back to the platform face: the baseline is reachable again.
      controller.appearancePreferenceOwner.replaceFontPreference('system');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(renderedFamily(), platformFamily);
    } finally {
      await tester.runAsync(composition.dispose);
      controller.dispose();
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
