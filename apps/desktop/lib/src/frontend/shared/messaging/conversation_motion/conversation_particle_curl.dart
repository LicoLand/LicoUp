import 'dart:math' as math;
import 'dart:typed_data';

/// A bounded, moving cache of the continuous curl of a simplex vector field.
///
/// The two shell octaves each own one cache. Cache cells are world coordinates,
/// so moving through a cell never changes the field or restarts its clock. Only
/// newly visited corners evaluate noise; particles interpolate the unnormalised
/// curl, then normalise it. This retains converging streamlines near a vortex
/// without evaluating twelve noise samples per particle, per octave, per frame.
class ConversationParticleCurl {
  ConversationParticleCurl({required double extent})
    : _side = (extent * 2 / spacing).ceil() + 3 {
    final cells = _side * _side * _side;
    _coordinates = Int32List(cells * 3)..fillRange(0, cells * 3, 0x7fffffff);
    _vectors = Float64List(cells * 3);
  }

  static const spacing = 0.075;
  final int _side;
  late final Int32List _coordinates;
  late final Float64List _vectors;

  int get allocatedBytes => _coordinates.lengthInBytes + _vectors.lengthInBytes;

  void sample(double x, double y, double z, Float64List output) {
    final gx = x / spacing;
    final gy = y / spacing;
    final gz = z / spacing;
    final ix = gx.floor();
    final iy = gy.floor();
    final iz = gz.floor();
    final tx = gx - ix;
    final ty = gy - iy;
    final tz = gz - iz;
    var vx = 0.0;
    var vy = 0.0;
    var vz = 0.0;
    for (var dx = 0; dx < 2; dx++) {
      final wx = dx == 0 ? 1 - tx : tx;
      for (var dy = 0; dy < 2; dy++) {
        final wxy = wx * (dy == 0 ? 1 - ty : ty);
        for (var dz = 0; dz < 2; dz++) {
          final weight = wxy * (dz == 0 ? 1 - tz : tz);
          final cx = ix + dx;
          final cy = iy + dy;
          final cz = iz + dz;
          final cell =
              (((cx % _side) * _side + cy % _side) * _side + cz % _side) * 3;
          if (_coordinates[cell] != cx ||
              _coordinates[cell + 1] != cy ||
              _coordinates[cell + 2] != cz) {
            _coordinates[cell] = cx;
            _coordinates[cell + 1] = cy;
            _coordinates[cell + 2] = cz;
            _curl(cx * spacing, cy * spacing, cz * spacing, _vectors, cell);
          }
          vx += _vectors[cell] * weight;
          vy += _vectors[cell + 1] * weight;
          vz += _vectors[cell + 2] * weight;
        }
      }
    }
    final length = math.sqrt(vx * vx + vy * vy + vz * vz);
    final scale = length > 0 ? 1 / length : 0.0;
    output[0] = vx * scale;
    output[1] = vy * scale;
    output[2] = vz * scale;
  }

  // Central differences of A=N(x,y,z), B=N(y-19.1,z+33.4,x+47.2),
  // C=N(z+74.2,x-124.5,y+99.4). Only the six required partial derivatives
  // are evaluated; the common 1/(2e) cancels when the curl is normalised.
  static void _curl(
    double x,
    double y,
    double z,
    Float64List output,
    int offset,
  ) {
    const e = 0.1;
    final noise = _SimplexNoise.sample;
    final ay = noise(x, y + e, z) - noise(x, y - e, z);
    final az = noise(x, y, z + e) - noise(x, y, z - e);
    final bx =
        noise(y - 19.1, z + 33.4, x + 47.2 + e) -
        noise(y - 19.1, z + 33.4, x + 47.2 - e);
    final bz =
        noise(y - 19.1, z + 33.4 + e, x + 47.2) -
        noise(y - 19.1, z + 33.4 - e, x + 47.2);
    final cx =
        noise(z + 74.2, x - 124.5 + e, y + 99.4) -
        noise(z + 74.2, x - 124.5 - e, y + 99.4);
    final cy =
        noise(z + 74.2, x - 124.5, y + 99.4 + e) -
        noise(z + 74.2, x - 124.5, y + 99.4 - e);
    output[offset] = cy - bz;
    output[offset + 1] = az - cx;
    output[offset + 2] = bx - ay;
  }
}

// Scalar, table-cached adaptation of the MIT-licensed 3D simplex algorithm:
// https://github.com/ashima/webgl-noise/blob/master/src/noise3D.glsl
// Copyright (C) 2011 by Ashima Arts (Simplex noise)
// Copyright (C) 2011-2016 by Stefan Gustavson (Classic noise and others)
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
class _SimplexNoise {
  static final _permutation = Uint16List.fromList([
    for (var i = 0; i < 289; i++) ((i * 34 + 1) * i) % 289,
  ]);
  static final _gradients = _buildGradients();

  static Float64List _buildGradients() {
    final result = Float64List(289 * 3);
    for (var i = 0; i < 289; i++) {
      final j = i % 49;
      var x = (j ~/ 7) * (2 / 7) - 13 / 14;
      var y = (j % 7) * (2 / 7) - 13 / 14;
      final z = 1 - x.abs() - y.abs();
      if (z <= 0) {
        x -= x.floor() * 2 + 1;
        y -= y.floor() * 2 + 1;
      }
      final scale =
          1.79284291400159 - 0.85373472095314 * (x * x + y * y + z * z);
      result[i * 3] = x * scale;
      result[i * 3 + 1] = y * scale;
      result[i * 3 + 2] = z * scale;
    }
    return result;
  }

  static double sample(double x, double y, double z) {
    final skew = (x + y + z) / 3;
    final ix = (x + skew).floor();
    final iy = (y + skew).floor();
    final iz = (z + skew).floor();
    final unskew = (ix + iy + iz) / 6;
    final x0 = x - ix + unskew;
    final y0 = y - iy + unskew;
    final z0 = z - iz + unskew;
    final gx = x0 >= y0 ? 1 : 0;
    final gy = y0 >= z0 ? 1 : 0;
    final gz = z0 >= x0 ? 1 : 0;
    final ax = math.min(gx, 1 - gz);
    final ay = math.min(gy, 1 - gx);
    final az = math.min(gz, 1 - gy);
    final bx = math.max(gx, 1 - gz);
    final by = math.max(gy, 1 - gx);
    final bz = math.max(gz, 1 - gy);
    return 42 *
        (_corner(ix, iy, iz, x0, y0, z0) +
            _corner(
              ix + ax,
              iy + ay,
              iz + az,
              x0 - ax + 1 / 6,
              y0 - ay + 1 / 6,
              z0 - az + 1 / 6,
            ) +
            _corner(
              ix + bx,
              iy + by,
              iz + bz,
              x0 - bx + 1 / 3,
              y0 - by + 1 / 3,
              z0 - bz + 1 / 3,
            ) +
            _corner(ix + 1, iy + 1, iz + 1, x0 - .5, y0 - .5, z0 - .5));
  }

  static double _corner(int ix, int iy, int iz, double x, double y, double z) {
    final falloff = .6 - x * x - y * y - z * z;
    if (falloff <= 0) return 0;
    final p = _permutation;
    final index = p[(p[(p[iz % 289] + iy) % 289] + ix) % 289] * 3;
    final g = _gradients;
    final m2 = falloff * falloff;
    return m2 * m2 * (g[index] * x + g[index + 1] * y + g[index + 2] * z);
  }
}
