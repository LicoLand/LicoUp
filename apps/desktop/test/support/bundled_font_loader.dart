import 'package:flutter/services.dart';

import 'package:licoup/src/frontend/shared/ui/lico_typography.dart';

/// Production fonts for synthetic visual acceptance. Tests never read system
/// fonts or download assets, so the same scene renders on every host.
///
/// The interface baseline is the platform's own family, and a test host has no
/// platform faces: without an alias the test engine would draw every role in
/// its own fallback face. The platform families are therefore registered onto
/// the bundled Geist files, which keeps rendered text real for pixel evidence
/// while the production path still resolves a platform family name.
Future<void> loadBundledVisualFonts() async {
  const sansWeights = <String>[
    'assets/fonts/GeistSans-Regular.ttf',
    'assets/fonts/GeistSans-Medium.ttf',
    'assets/fonts/GeistSans-SemiBold.ttf',
    'assets/fonts/GeistSans-Bold.ttf',
  ];
  const monoWeights = <String>[
    'assets/fonts/GeistMono-Regular.ttf',
    'assets/fonts/GeistMono-Medium.ttf',
  ];
  final families = <String, List<String>>{
    // The bundled family itself, as the client ships it.
    LicoTypography.bundledSansFamily: sansWeights,
    LicoTypography.monoFamily: monoWeights,
    // One alias per platform interface family, so a theme resolved for any
    // platform renders real glyphs under test.
    for (final platformFamily in <String>{
      for (final platform in TargetPlatform.values)
        LicoTypography.sansFamilyFor(platform),
    })
      platformFamily: sansWeights,
    'MaterialIcons': const ['fonts/MaterialIcons-Regular.otf'],
  };

  for (final entry in families.entries) {
    final loader = FontLoader(entry.key);
    for (final path in entry.value) {
      loader.addFont(rootBundle.load(path));
    }
    await loader.load();
  }
}
