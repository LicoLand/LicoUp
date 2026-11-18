import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// Actual bounds in the conversation overlay's local coordinate system.
@immutable
class ConversationMotionAnchors {
  const ConversationMotionAnchors({
    required this.content,
    this.avatar,
    this.composer,
  });

  final Rect content;
  final Rect? avatar;
  final RRect? composer;

  bool get hasDestinations =>
      avatar != null &&
      !avatar!.isEmpty &&
      composer != null &&
      !composer!.isEmpty;

  @override
  bool operator ==(Object other) =>
      other is ConversationMotionAnchors &&
      content == other.content &&
      avatar == other.avatar &&
      composer == other.composer;

  @override
  int get hashCode => Object.hash(content, avatar, composer);
}

/// A locally sampled brand mark, with x/y pairs normalized to its avatar bounds.
///
/// Supply only an application-rendered avatar/brand mark. No conversation or
/// user-content capture is needed. The image and its bytes are never retained.
class ConversationMotionGlyph {
  ConversationMotionGlyph(Float32List normalizedPositions)
    : normalizedPositions = Float32List.fromList(normalizedPositions) {
    if (normalizedPositions.isEmpty || normalizedPositions.length.isOdd) {
      throw ArgumentError.value(normalizedPositions.length, 'positions.length');
    }
  }

  final Float32List normalizedPositions;
  int get length => normalizedPositions.length ~/ 2;

  static Future<ConversationMotionGlyph?> fromImage(ui.Image image) async {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (bytes == null) return null;
    return fromRgba(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      width: image.width,
      height: image.height,
    );
  }

  static ConversationMotionGlyph? fromRgba(
    Uint8List bytes, {
    required int width,
    required int height,
  }) {
    if (width <= 0 || height <= 0 || bytes.length != width * height * 4) {
      throw ArgumentError('RGBA dimensions must match the byte buffer.');
    }
    final points = <double>[];
    // Sampling is bounded by mark resolution, independently of display DPI.
    final step = math.max(1, (math.max(width, height) / 72).ceil());
    for (var y = 0; y < height; y += step) {
      for (var x = 0; x < width; x += step) {
        if (bytes[(y * width + x) * 4 + 3] < 48) continue;
        points
          ..add((x + 0.5) / width)
          ..add((y + 0.5) / height);
      }
    }
    return points.isEmpty
        ? null
        : ConversationMotionGlyph(Float32List.fromList(points));
  }
}
