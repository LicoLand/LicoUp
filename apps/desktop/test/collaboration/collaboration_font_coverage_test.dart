import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/shared/ui/lico_typography.dart';

import '../support/bundled_font_loader.dart';

/// Renders [char] with the interface sans chain and returns the rasterised
/// pixels. Two different codepoints sharing an identical bitmap means the
/// resolved face drew a fallback box instead of a real glyph.
Future<List<int>> renderChar(String char, {List<String>? fallback}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final painter = TextPainter(
    text: TextSpan(
      text: char,
      style: TextStyle(
        fontFamily: '.AppleSystemUIFont',
        fontFamilyFallback: fallback ?? LicoTypography.sansFallback,
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: Colors.white,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  painter.paint(canvas, Offset.zero);
  final image = await recorder.endRecording().toImage(
    painter.width.ceil() + 4,
    painter.height.ceil() + 4,
  );
  final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  return bytes!.buffer.asUint8List().toList();
}

String digest(List<int> px) {
  var h = 5381;
  for (final b in px) {
    h = ((h << 5) + h + b) & 0x7fffffff;
  }
  return '$h';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadBundledVisualFonts);

  // The Chinese text the collaboration goldens render. A missing fallback
  // alias once let a host face claim the most common characters, so the
  // goldens must not trust pixel similarity alone — every codepoint has to
  // resolve to its own real glyph.
  const covered = '本文试中构建地索引超大件重上限进行的是了，。决';

  test('every CJK codepoint in the goldens resolves a real glyph', () async {
    final emptyFaceDigests = <String>{
      for (final char in covered.split(''))
        digest(await renderChar(char, fallback: const [])),
    };
    expect(
      emptyFaceDigests.length,
      1,
      reason: 'the Latin-only face should draw one identical box for all',
    );
    final tofu = emptyFaceDigests.single;

    final byDigest = <String, List<String>>{};
    for (final char in covered.split('')) {
      byDigest.putIfAbsent(digest(await renderChar(char)), () => []).add(char);
    }
    expect(
      byDigest.keys,
      isNot(contains(tofu)),
      reason: 'no codepoint may resolve to the same box the empty face draws',
    );
    expect(
      byDigest.length,
      covered.length,
      reason: 'every codepoint must render a distinct glyph: $byDigest',
    );
  });
}
