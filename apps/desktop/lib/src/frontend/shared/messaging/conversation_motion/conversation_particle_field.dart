import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'package:licoup/src/frontend/shared/messaging/conversation_motion/conversation_particle_geometry.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

export 'conversation_particle_geometry.dart';

/// Decorative, pointer-transparent identity assembly over the live conversation.
/// Only particle points are painted; the caller's background stays untouched.
///
/// Give each conversation its own key. [assembled] starts a single continuous
/// shell → leftward sheet → actual avatar/composer path. No functional state,
/// sending, first-response rendering or cancellation depends on this widget.
class ConversationParticleField extends StatefulWidget {
  const ConversationParticleField({
    super.key,
    required this.assembled,
    required this.anchors,
    this.avatarGlyph,
    this.onAssembled,
    this.particleCount = 30000,
  });

  final bool assembled;
  final ConversationParticleAnchors anchors;
  final ConversationParticleGlyph? avatarGlyph;
  final VoidCallback? onAssembled;
  final int particleCount;

  @override
  State<ConversationParticleField> createState() =>
      _ConversationParticleFieldState();
}

class _ConversationParticleFieldState extends State<ConversationParticleField>
    with SingleTickerProviderStateMixin {
  late ConversationParticleGeometry _geometry;
  late ConversationParticlePaintBuffer _paintBuffer;
  late final Ticker _ticker;
  final _clock = ValueNotifier<double>(0);
  double _startSeconds = 0;
  double _timeScale = 1;
  bool _completed = false;
  bool _reduced = false;

  @override
  void initState() {
    super.initState();
    _geometry = ConversationParticleGeometry(count: widget.particleCount);
    _paintBuffer = ConversationParticlePaintBuffer(widget.particleCount);
    _ticker = createTicker(_tick);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = context.motion(LicoMotion.loopLong) == Duration.zero;
    _sync();
  }

  @override
  void didUpdateWidget(ConversationParticleField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.particleCount != widget.particleCount ||
        (oldWidget.assembled && !widget.assembled)) {
      _geometry = ConversationParticleGeometry(count: widget.particleCount);
      _paintBuffer = ConversationParticlePaintBuffer(widget.particleCount);
      _completed = false;
    } else if (!_completed &&
        _geometry.isAssembling &&
        (oldWidget.anchors != widget.anchors ||
            oldWidget.avatarGlyph != widget.avatarGlyph) &&
        widget.anchors.hasDestinations) {
      _geometry.assemble(
        seconds: _clock.value,
        duration: math.max(
          _geometry.endTime - _clock.value,
          LicoMotion.medium.inMicroseconds / Duration.microsecondsPerSecond,
        ),
        anchors: widget.anchors,
        glyph: widget.avatarGlyph,
      );
    }
    _sync();
  }

  void _sync() {
    if (_reduced && widget.assembled) {
      _ticker.stop();
      _complete();
      return;
    }
    if (widget.assembled &&
        !_geometry.isAssembling &&
        !_completed &&
        widget.anchors.hasDestinations) {
      _geometry.assemble(
        seconds: _clock.value,
        duration:
            (LicoMotion.loopLong + LicoMotion.long).inMicroseconds /
            Duration.microsecondsPerSecond,
        anchors: widget.anchors,
        glyph: widget.avatarGlyph,
      );
    }
    if (_completed || _reduced || !context.allowsAmbientMotion) {
      _ticker.stop();
      return;
    }
    final timeScale =
        LicoMotion.loopLong.inMicroseconds /
        context.motion(LicoMotion.loopLong).inMicroseconds;
    if (_ticker.isActive && _timeScale == timeScale) return;
    _ticker.stop();
    _startSeconds = _clock.value;
    _timeScale = timeScale;
    _ticker.start();
  }

  void _tick(Duration elapsed) {
    _clock.value =
        _startSeconds +
        elapsed.inMicroseconds / Duration.microsecondsPerSecond * _timeScale;
    if (_geometry.isAssembling && _clock.value >= _geometry.endTime) {
      _ticker.stop();
      _complete();
    }
  }

  void _complete() {
    if (_completed) return;
    _completed = true;
    // Reduced-motion completion can occur while dependencies are rebuilding.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _completed) widget.onAssembled?.call();
    });
  }

  @override
  void dispose() {
    _ticker.dispose();
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return ExcludeSemantics(
      child: IgnorePointer(
        child: RepaintBoundary(
          child: CustomPaint(
            painter: ConversationParticlePainter(
              geometry: _geometry,
              anchors: widget.anchors,
              clock: _clock,
              color: colors.isDark ? colors.accentStrong : colors.textSecondary,
              buffer: _paintBuffer,
              hidden: _reduced && widget.assembled,
            ),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
  }
}

/// Counting-sort workspace shared across painter replacements (e.g. a theme
/// change). One contiguous point buffer costs O(N), not one N-sized buffer for
/// every shade. No per-frame backing arrays or per-particle objects are needed.
class ConversationParticlePaintBuffer {
  ConversationParticlePaintBuffer(int count)
    : points = Float32List(count * 2),
      buckets = Uint8List(count);

  final Float32List points;
  final Uint8List buckets;
  final lengths = Uint32List(48);
  final offsets = Uint32List(49);
}

/// Batches all particles into 48 size/opacity buckets; no per-particle widgets,
/// paint objects or frame-sized buffers are created in the paint pass.
class ConversationParticlePainter extends CustomPainter {
  ConversationParticlePainter({
    required this.geometry,
    required this.anchors,
    required this.clock,
    required this.color,
    ConversationParticlePaintBuffer? buffer,
    this.hidden = false,
  }) : buffer = buffer ?? ConversationParticlePaintBuffer(geometry.count),
       _paints = List.generate(48, (bucket) {
         final level = bucket % 16;
         return Paint()
           ..color = color.withValues(alpha: (level + 1) / 16)
           ..strokeWidth = 0.44 + (bucket ~/ 16) * 0.18
           ..strokeCap = StrokeCap.round
           ..isAntiAlias = true;
       }),
       super(repaint: clock);

  final ConversationParticleGeometry geometry;
  final ConversationParticleAnchors anchors;
  final ValueListenable<double> clock;
  final Color color;
  final bool hidden;
  final ConversationParticlePaintBuffer buffer;
  final List<Paint> _paints;

  @override
  void paint(Canvas canvas, Size size) {
    if (hidden ||
        size.isEmpty ||
        (geometry.isAssembling && clock.value >= geometry.endTime)) {
      return;
    }
    geometry.writeFrame(clock.value, anchors);
    final lengths = buffer.lengths;
    lengths.fillRange(0, lengths.length, 0);
    final lightParticles = color.computeLuminance() > 0.45;
    for (var i = 0; i < geometry.count; i++) {
      final light = geometry.luminance[i];
      final opacity =
          (lightParticles ? 0.16 + light * 0.54 : 0.12 + light * 0.22) *
          geometry.opacity[i];
      if (opacity < 0.035) {
        buffer.buckets[i] = 255;
        continue;
      }
      final diameter = (geometry.depth[i] * 2.99).floor();
      final bucket = diameter * 16 + (opacity * 15).floor().clamp(0, 15);
      buffer.buckets[i] = bucket;
      lengths[bucket] += 2;
    }
    for (var bucket = 0; bucket < lengths.length; bucket++) {
      buffer.offsets[bucket + 1] = buffer.offsets[bucket] + lengths[bucket];
    }
    lengths.fillRange(0, lengths.length, 0);
    for (var i = 0; i < geometry.count; i++) {
      final bucket = buffer.buckets[i];
      if (bucket == 255) continue;
      final offset = buffer.offsets[bucket] + lengths[bucket];
      buffer.points[offset] = geometry.positions[i * 2];
      buffer.points[offset + 1] = geometry.positions[i * 2 + 1];
      lengths[bucket] += 2;
    }
    for (var bucket = 0; bucket < lengths.length; bucket++) {
      final length = lengths[bucket];
      if (length == 0) continue;
      final start = buffer.offsets[bucket];
      canvas.drawRawPoints(
        ui.PointMode.points,
        Float32List.sublistView(buffer.points, start, start + length),
        _paints[bucket],
      );
    }
  }

  @override
  bool shouldRepaint(ConversationParticlePainter oldDelegate) =>
      geometry != oldDelegate.geometry ||
      anchors != oldDelegate.anchors ||
      clock != oldDelegate.clock ||
      color != oldDelegate.color ||
      hidden != oldDelegate.hidden;
}
