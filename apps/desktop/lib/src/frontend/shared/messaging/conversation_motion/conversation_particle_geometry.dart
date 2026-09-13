import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'conversation_particle_curl.dart';

/// Actual bounds in the particle overlay's local coordinate system.
@immutable
class ConversationParticleAnchors {
  const ConversationParticleAnchors({
    required this.sphere,
    this.avatar,
    this.composer,
  });

  final Rect sphere;
  final Rect? avatar;
  final RRect? composer;

  bool get hasDestinations =>
      avatar != null &&
      !avatar!.isEmpty &&
      composer != null &&
      !composer!.isEmpty;

  @override
  bool operator ==(Object other) =>
      other is ConversationParticleAnchors &&
      sphere == other.sphere &&
      avatar == other.avatar &&
      composer == other.composer;

  @override
  int get hashCode => Object.hash(sphere, avatar, composer);
}

/// A locally sampled brand mark, with x/y pairs normalized to its avatar bounds.
///
/// Supply only an application-rendered avatar/brand mark. No conversation or
/// user-content capture is needed. The image and its bytes are never retained.
class ConversationParticleGlyph {
  ConversationParticleGlyph(Float32List normalizedPositions)
    : normalizedPositions = Float32List.fromList(normalizedPositions) {
    if (normalizedPositions.isEmpty || normalizedPositions.length.isOdd) {
      throw ArgumentError.value(normalizedPositions.length, 'positions.length');
    }
  }

  final Float32List normalizedPositions;
  int get length => normalizedPositions.length ~/ 2;

  static Future<ConversationParticleGlyph?> fromImage(ui.Image image) async {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (bytes == null) return null;
    return fromRgba(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      width: image.width,
      height: image.height,
    );
  }

  static ConversationParticleGlyph? fromRgba(
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
        : ConversationParticleGlyph(Float32List.fromList(points));
  }
}

/// Stable Fibonacci samples of a thin, continuously folding particle shell.
///
/// Two simplex curl octaves displace particles tangentially before the radius
/// is restored. Density folds through itself while the silhouette stays round;
/// there are no latitude bands, radial breathing or rigid grid rotations.
/// The bounded curl caches and frame arrays are reused throughout its lifetime.
class ConversationParticleGeometry {
  ConversationParticleGeometry({this.count = 30000})
    : assert(count > 0),
      positions = Float32List(count * 2),
      luminance = Float32List(count),
      depth = Float32List(count),
      opacity = Float32List(count),
      _basis = Float64List(count * 5),
      _source = Float64List(count * 6),
      _wave = Float64List(count * 4),
      _target = Float64List(count * 2),
      _launch = Float64List(count),
      _waveTime = Float64List(count),
      _sourceOpacity = Float32List(count),
      _sourceDepth = Float32List(count),
      _sourceLight = Float32List(count),
      _scratch = Float64List(4) {
    final goldenAngle = math.pi * (3 - math.sqrt(5));
    for (var i = 0; i < count; i++) {
      final y = 1 - 2 * (i + 0.5) / count;
      final angle = goldenAngle * i;
      final ring = math.sqrt(1 - y * y);
      final k = i * 5;
      _basis[k] = ring * math.cos(angle);
      _basis[k + 1] = y;
      _basis[k + 2] = ring * math.sin(angle);
      _basis[k + 3] = (angle / (math.pi * 2)) % 1;
      _basis[k + 4] = (i * 0.618033988749895) % 1;
    }
  }

  final int count;
  final Float32List positions;
  final Float32List luminance;
  final Float32List depth;
  final Float32List opacity;
  final Float64List _basis;
  final Float64List _source;
  final Float64List _wave;
  final Float64List _target;
  final Float64List _launch;
  final Float64List _waveTime;
  final Float32List _sourceOpacity;
  final Float32List _sourceDepth;
  final Float32List _sourceLight;
  final Float64List _scratch;
  ConversationParticleAnchors? _anchors;
  double? _start;
  double _duration = 0;
  static const _curlDepartureFraction = 0.18;
  bool _curlDeparture = false;
  double _curlDepartureEnd = 0;
  final _broadCurl = ConversationParticleCurl(extent: 0.36);
  final _fineCurl = ConversationParticleCurl(extent: 0.72);
  final _curl = Float64List(3);
  double _seconds = 0;
  double _sinTurn = 0;
  double _cosTurn = 1;

  bool get isAssembling => _start != null;
  double get endTime => (_start ?? 0) + _duration;

  int get allocatedBytes =>
      positions.lengthInBytes +
      luminance.lengthInBytes +
      depth.lengthInBytes +
      opacity.lengthInBytes +
      _basis.lengthInBytes +
      _source.lengthInBytes +
      _wave.lengthInBytes +
      _target.lengthInBytes +
      _launch.lengthInBytes +
      _waveTime.lengthInBytes +
      _sourceOpacity.lengthInBytes +
      _sourceDepth.lengthInBytes +
      _sourceLight.lengthInBytes +
      _scratch.lengthInBytes +
      _curl.lengthInBytes +
      _broadCurl.allocatedBytes +
      _fineCurl.allocatedBytes;

  void _setTime(double seconds) {
    _seconds = seconds;
    _sinTurn = math.sin(seconds * 0.12 - 0.2);
    _cosTurn = math.cos(seconds * 0.12 - 0.2);
  }

  void _spherePoint(int i, Rect sphere, Float64List output) {
    final k = i * 5;
    final x = _basis[k];
    final y = _basis[k + 1];
    final z = _basis[k + 2];
    final broadTime = _seconds * 0.1;
    final fineTime = _seconds * 0.15;
    _broadCurl.sample(
      x * 0.36 + broadTime,
      y * 0.36 + broadTime,
      z * 0.36 + broadTime,
      _curl,
    );
    var cx = _curl[0];
    var cy = _curl[1];
    var cz = _curl[2];
    _fineCurl.sample(
      x * 0.72 + fineTime,
      y * 0.72 + fineTime,
      z * 0.72 + fineTime,
      _curl,
    );
    cx += _curl[0] * 0.5;
    cy += _curl[1] * 0.5;
    cz += _curl[2] * 0.5;
    final radialCurl = cx * x + cy * y + cz * z;
    final sx = x + (cx - x * radialCurl) * 0.98;
    final sy = y + (cy - y * radialCurl) * 0.98;
    final sz = z + (cz - z * radialCurl) * 0.98;
    final shell = 1 / math.sqrt(sx * sx + sy * sy + sz * sz);
    final px = sx * shell;
    final py = sy * shell;
    final pz = sz * shell;
    final rx = px * _cosTurn + pz * _sinTurn;
    final rz = -px * _sinTurn + pz * _cosTurn;
    final radius = sphere.shortestSide * 0.46;
    final perspective = 3.9 / (3.9 - rz);
    output[0] = sphere.left + sphere.width / 2 + rx * radius * perspective;
    output[1] = sphere.top + sphere.height / 2 - py * radius * perspective;
    output[2] = (rz + 1) / 2;
    // Neutral side lighting preserves translucency on both overlapping shells.
    final nx = x * _cosTurn + z * _sinTurn;
    final nz = -x * _sinTurn + z * _cosTurn;
    final sideLight =
        math.max(0, -nx * 0.8944 + nz * 0.4472) +
        math.max(0, nx * 0.8944 + nz * 0.4472);
    output[3] = (0.1 + sideLight * 0.9).clamp(0.0, 1.0);
  }

  /// Capture position, velocity and acceleration before creating a C2 path.
  /// Retargeting during resize carries all three into the remaining segment.
  void assemble({
    required double seconds,
    required double duration,
    required ConversationParticleAnchors anchors,
    ConversationParticleGlyph? glyph,
  }) {
    assert(anchors.hasDestinations);
    assert(duration > 0);
    final retarget = _start != null;
    const delta = 0.002;
    final before = Float64List(count * 2);
    final current = Float64List(count * 2);
    final after = Float64List(count * 2);
    if (retarget) {
      writeFrame(seconds - delta, _anchors!);
      before.setAll(0, positions);
      writeFrame(seconds, _anchors!);
      current.setAll(0, positions);
      writeFrame(seconds + delta, _anchors!);
      after.setAll(0, positions);
      writeFrame(seconds, _anchors!);
    }
    // Early body/layout measurements can retarget the flight immediately after
    // release. Keep the same short impulse window through those measurements.
    _curlDeparture = !retarget || seconds < _curlDepartureEnd;
    if (!retarget) _curlDepartureEnd = seconds;
    _anchors = anchors;
    final radius = anchors.sphere.shortestSide * 0.46;
    final outline = Path()..addRRect(anchors.composer!.scaleRadii());
    final metric = outline.computeMetrics().first;
    for (var i = 0; i < count; i++) {
      final k = i * 5;
      final p = i * 2;
      final s = i * 6;
      final w = i * 4;
      final u = _basis[k + 3];
      final v = _basis[k + 1];
      final seed = _basis[k + 4];
      final delay = retarget
          ? 0.0
          : duration * (0.08 * (_basis[k] + 1) / 2 + seed * 0.07);
      _launch[i] = seconds + delay;
      _sourceOpacity[i] = retarget ? opacity[i] : 1;
      _sourceDepth[i] = depth[i];
      _sourceLight[i] = luminance[i];
      if (!retarget) {
        _waveTime[i] = seconds + delay + (duration - delay) * 0.49;
        _curlDepartureEnd = math.max(
          _curlDepartureEnd,
          _launch[i] + (_waveTime[i] - _launch[i]) * _curlDepartureFraction,
        );
      }
      if (!retarget) {
        for (var sample = -1; sample <= 1; sample++) {
          _setTime(seconds + delay + sample * delta);
          _spherePoint(i, anchors.sphere, _scratch);
          final buffer = sample < 0 ? before : (sample == 0 ? current : after);
          buffer[p] = _scratch[0];
          buffer[p + 1] = _scratch[1];
          if (sample == 0) {
            _sourceDepth[i] = _scratch[2];
            _sourceLight[i] = _scratch[3];
          }
        }
      }
      for (var axis = 0; axis < 2; axis++) {
        _source[s + axis] = current[p + axis];
        _source[s + 2 + axis] =
            (after[p + axis] - before[p + axis]) / (2 * delta);
        _source[s + 4 + axis] =
            (after[p + axis] - 2 * current[p + axis] + before[p + axis]) /
            (delta * delta);
      }
      // Unwrap into a tapered, volumetric ribbon. A rectangular UV sheet has
      // conspicuous hard corners; the latitude envelope and stable thickness
      // instead let individual identities feather into a curved wave bundle.
      final envelope = math.sqrt(1 - v * v);
      final along = (u * 2 - 1) * envelope + (seed - 0.5) * 0.05;
      final wavePhase = along * math.pi * 1.4 + v * 0.35;
      final cross = v * (0.18 + 0.04 * math.cos(along * math.pi));
      _wave[w] = anchors.sphere.center.dx - radius * (1.30 - 1.1 * along);
      _wave[w + 1] =
          anchors.sphere.center.dy +
          radius *
              (math.sin(wavePhase) * 0.28 +
                  cross +
                  (seed - 0.5) * 0.18 +
                  _basis[k + 2] * 0.04);
      if (!retarget) {
        _wave[w + 2] = -radius * 0.85 / duration;
        _wave[w + 3] =
            _wave[w + 2] * (0.28 * math.pi * 1.4 / 1.1) * math.cos(wavePhase);
      }
      if (seed < 0.32) {
        final avatar = anchors.avatar!;
        if (glyph != null) {
          final sample =
              ((seed / 0.32) * glyph.length).floor().clamp(
                0,
                glyph.length - 1,
              ) *
              2;
          _target[p] =
              avatar.left + glyph.normalizedPositions[sample] * avatar.width;
          _target[p + 1] =
              avatar.top +
              glyph.normalizedPositions[sample + 1] * avatar.height;
        } else {
          // Until the real mark is sampled, converge only to its actual rim.
          final angle = seed / 0.32 * math.pi * 2;
          _target[p] = avatar.center.dx + math.cos(angle) * avatar.width / 2;
          _target[p + 1] =
              avatar.center.dy + math.sin(angle) * avatar.height / 2;
        }
      } else {
        final tangent = metric.getTangentForOffset(
          (seed - 0.32) / 0.68 * metric.length,
        )!;
        _target[p] = tangent.position.dx;
        _target[p + 1] = tangent.position.dy;
      }
    }
    _start = seconds;
    _duration = duration;
    writeFrame(seconds, anchors);
  }

  void writeFrame(double seconds, ConversationParticleAnchors anchors) {
    _setTime(seconds);
    final assembling = _start != null;
    for (var i = 0; i < count; i++) {
      final p = i * 2;
      if (!assembling || seconds < _launch[i]) {
        _spherePoint(i, anchors.sphere, _scratch);
        depth[i] = _scratch[2];
        luminance[i] = _scratch[3];
        positions[p] = _scratch[0];
        positions[p + 1] = _scratch[1];
        opacity[i] = 1;
        continue;
      }
      final localDuration = endTime - _launch[i];
      final t = ((seconds - _launch[i]) / localDuration).clamp(0.0, 1.0);
      final s = i * 6;
      final w = i * 4;
      final hasWave = _waveTime[i] > _launch[i];
      for (var axis = 0; axis < 2; axis++) {
        if (!hasWave) {
          positions[p + axis] = _quintic(
            t,
            localDuration,
            _source[s + axis],
            _source[s + 2 + axis],
            _source[s + 4 + axis],
            _target[p + axis],
            0,
          );
        } else if (seconds < _waveTime[i]) {
          final segmentDuration = _waveTime[i] - _launch[i];
          positions[p + axis] = _quintic(
            (seconds - _launch[i]) / segmentDuration,
            segmentDuration,
            _source[s + axis],
            _source[s + 2 + axis],
            _source[s + 4 + axis],
            _wave[w + axis],
            _wave[w + 2 + axis],
            curlDeparture: _curlDeparture,
          );
        } else {
          final segmentDuration = endTime - _waveTime[i];
          positions[p + axis] = _quintic(
            ((seconds - _waveTime[i]) / segmentDuration).clamp(0.0, 1.0),
            segmentDuration,
            _wave[w + axis],
            _wave[w + 2 + axis],
            0,
            _target[p + axis],
            0,
          );
        }
      }
      // Identity paths finish on real UI. Only the final deposited particles
      // fade; the live avatar, composer and first reply never wait for this.
      opacity[i] =
          _sourceOpacity[i] *
          (1 - _smooth(((t - 0.82) / 0.18).clamp(0.0, 1.0)));
      depth[i] = _sourceDepth[i] * (1 - t) + 0.67 * t;
      luminance[i] = _sourceLight[i];
    }
  }

  static double _smooth(double t) => t * t * t * (10 + t * (-15 + 6 * t));

  static double _quintic(
    double t,
    double duration,
    double start,
    double velocity,
    double acceleration,
    double end,
    double endVelocity, {
    bool curlDeparture = false,
  }) {
    final t2 = t * t;
    final t3 = t2 * t;
    final t4 = t3 * t;
    final t5 = t4 * t;
    // The live curl can briefly have strong local acceleration at a fold.
    // Carry its exact position/velocity/acceleration across release, but let
    // that local Taylor motion expire over the first 18% of the departure.
    // Integrating it over the whole one-second wave segment would throw a few
    // particles far away from the sheet. The window has zero first/second
    // derivatives at both ends, so the shell and wave still meet with C2 motion.
    final departureWindow = curlDeparture
        ? 1 - _smooth((t / _curlDepartureFraction).clamp(0.0, 1.0))
        : 1.0;
    final velocityBasis = curlDeparture
        ? t * departureWindow
        : t - 6 * t3 + 8 * t4 - 3 * t5;
    final accelerationBasis = curlDeparture
        ? t2 * departureWindow
        : t2 - 3 * t3 + 3 * t4 - t5;
    return start * (1 - 10 * t3 + 15 * t4 - 6 * t5) +
        end * (10 * t3 - 15 * t4 + 6 * t5) +
        velocity * duration * velocityBasis +
        endVelocity * duration * (-4 * t3 + 7 * t4 - 3 * t5) +
        acceleration * duration * duration * accelerationBasis / 2;
  }
}
