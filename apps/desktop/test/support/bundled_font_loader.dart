import 'dart:io';

import 'package:flutter/services.dart';

import 'package:licoup/src/frontend/shared/ui/lico_typography.dart';

/// Production fonts for synthetic visual acceptance. Tests never read system
/// fonts or download assets, so the same scene renders on every host.
///
/// The interface baseline is the platform's own family. The test engine's font
/// manager can still resolve unregistered family names against the host
/// operating system — a macOS host answers 'PingFang SC' or 'SF Pro Text' with
/// real faces whose coverage differs from the bundled fonts — so every family
/// in the production fallback chains is registered explicitly and nothing is
/// left for the host to supply.
///
/// Latin families resolve onto the bundled Geist files and the Chinese faces
/// onto the test-owned Noto Sans SC file, which keeps rendered text real for
/// pixel evidence while the production path still resolves platform families.
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
  // The CJK face is a test fixture, not a shipped asset: it lives under
  // test/fonts so the client's asset tree stays free of a Chinese-sized font.
  const cjkFace = 'test/fonts/NotoSansSC.ttf';
  const cjkWeights = <String>[cjkFace];
  final aliasedSans = <String>{
    for (final platform in TargetPlatform.values)
      LicoTypography.sansFamilyFor(platform),
    ...LicoTypography.cjkSansFamilies,
    LicoTypography.bundledSansFamily,
  };
  final families = <String, List<String>>{
    // The bundled families, as the client ships them.
    LicoTypography.bundledSansFamily: sansWeights,
    LicoTypography.monoFamily: monoWeights,
    // Every named family in the sans chain gets a bundled face: the platform
    // Chinese faces read the bundled Noto Sans SC file, and every other
    // family — including the generic tail — reads Geist so no unregistered
    // name can leak through to a host face mid-chain.
    for (final family in LicoTypography.sansFallback)
      family: LicoTypography.cjkSansFamilies.contains(family)
          ? cjkWeights
          : sansWeights,
    // The platform interface families a resolved theme can head the chain
    // with even when they are absent from the fallback list.
    for (final platformFamily in aliasedSans)
      if (!LicoTypography.sansFallback.contains(platformFamily))
        platformFamily: LicoTypography.cjkSansFamilies.contains(platformFamily)
            ? cjkWeights
            : sansWeights,
    // The named mono fallbacks resolve onto Geist Mono for the same reason.
    for (final family in LicoTypography.monoFallback) family: monoWeights,
    'MaterialIcons': const ['fonts/MaterialIcons-Regular.otf'],
  };

  ByteData loadFontFile(String path) {
    // A synchronous read: tests also call this loader inside the test body,
    // where a real dart:io future never completes under the fake-async zone.
    final bytes = File(path).readAsBytesSync();
    return ByteData.sublistView(Uint8List.fromList(bytes));
  }

  for (final entry in families.entries) {
    final loader = FontLoader(entry.key);
    for (final path in entry.value) {
      // Only the CJK aliases use the Noto fixture, and they read the file
      // directly because it is not a bundle asset.
      loader.addFont(
        path == cjkFace
            ? Future<ByteData>.value(loadFontFile(path))
            : rootBundle.load(path),
      );
    }
    await loader.load();
  }
}
