#include <flutter/runtime_effect.glsl>

// Ambient spiral galaxy for the starlit preset. Mirrors its numpy
// procedural prototype 1:1: same hash, noise, star and
// disk-star layers, density-wave arms, glass transfer. All evaluation is in
// logical points (fragCoord / u_dpr), so the core lands at (0.15W, 0.80H).

uniform vec2 u_size;        // logical ground size (pt)
uniform float u_dpr;        // device pixel ratio (unused: frag is logical)
uniform float u_time;       // seconds
uniform float u_glassCount; // 0..4
uniform vec4 u_glass0;      // l,t,r,b (logical pt)
uniform vec4 u_glass1;
uniform vec4 u_glass2;
uniform vec4 u_glass3;
uniform vec4 u_glassRadius; // corner radius per rect
uniform vec4 u_trail0;      // x, y, amplitude, unused — 6 pointer slots
uniform vec4 u_trail1;
uniform vec4 u_trail2;
uniform vec4 u_trail3;
uniform vec4 u_trail4;
uniform vec4 u_trail5;
uniform vec4 u_parallax;    // smoothed parallax offset (pt)

out vec4 fragColor;

const float TAU = 6.283185307179586;
const float PI = 3.141592653589793;

// Model constants (prototype P dict).
const float CORE_X = 0.15, CORE_Y = 0.80, TILT = -24.0, INCL = 0.55;
const float SCALE = 0.90;
const float WIND = 2.3, SHARP = 3.2, WARP = 0.6, ENV = 0.34;
const float BULGE = 2.2, BULGE_R = 0.035, HALO = 0.04, HALO_R = 0.60;
const float ARM_GAIN = 0.95, DUST = 0.75, EXPOSURE = 1.5;
const float GRAIN = 0.9, KNOTS = 1.0, BG_STARS = 1.0;
const float GLASS_GAIN = 1.55, GLASS_GAMMA = 1.35, GLASS_KEEP = 0.95;
const float GLASS_KNEE = 0.22, GLASS_CEIL = 0.46;
// Sharp (unglazed) sky only: thin nebulosity with fine structure, crisp
// resolved stars, sharp dust lanes and a sparse bright star tier.
const float NEB = 0.70, CLUMP_FREQ = 40.0, CLUMP_LO = 0.25, CLUMP_HI = 1.6;
const float DUST_POW = 16.0;
const float GRAIN_CELL = 1.8, GRAIN_PROB = 0.55, GRAIN_LO = 0.28;
const float GRAIN_HI = 0.55, GRAIN_GAIN = 1.0;
const float BG_PROB = 0.16, BG_HI = 1.2;
const float BG2_CELL = 41.0, BG2_PROB = 0.25, BG2_LO = 0.6, BG2_HI = 1.4;
const float BG2_GAIN = 1.6, BG2_GOLD = 0.12;

float hash2(float ix, float iy) {
  // Dave Hoskins hash12, evaluated in float32 like the prototype.
  vec3 p = vec3(ix, iy, ix) * 0.1031;
  p = fract(p);
  p += dot(p, p.yzx + 33.33);
  return fract((p.x + p.y) * p.z);
}

float vnoise(float x, float y) {
  float ix = floor(x), iy = floor(y);
  float fx = x - ix, fy = y - iy;
  float ux = fx * fx * (3.0 - 2.0 * fx);
  float uy = fy * fy * (3.0 - 2.0 * fy);
  float a = hash2(ix, iy);
  float b = hash2(ix + 1.0, iy);
  float c = hash2(ix, iy + 1.0);
  float d = hash2(ix + 1.0, iy + 1.0);
  return a + (b - a) * ux + (c - a) * uy + (a - b - c + d) * ux * uy;
}

float fbm(float x, float y, int octaves) {
  float s = 0.0;
  float amp = 0.5;
  for (int i = 0; i < 5; i++) {
    if (i >= octaves) break;
    s += amp * vnoise(x, y);
    x = x * 2.03 + 17.1;
    y = y * 2.03 + 3.7;
    amp *= 0.5;
  }
  return s;
}

float omegaOf(float rpx, float S) {
  float r = rpx / S;
  return TAU / (120.0 + 780.0 * clamp(r, 0.0, 1.2));
}

// One jittered star per cell with probability `prob`; 3x3 neighbours when
// soft so soft stars never clip at cell edges. Returns (total, goldHash).
vec2 starLayer(vec2 px, float cell, float prob, float sizeLo, float sizeHi,
               bool soft, float seed, float T) {
  vec2 g = px / cell;
  vec2 b = floor(g);
  float total = 0.0;
  float gold = 1.0;
  for (int i = -1; i <= 1; i++) {
    for (int j = -1; j <= 1; j++) {
      if (!soft && (i != 0 || j != 0)) continue;
      float ix = b.x + float(i);
      float iy = b.y + float(j);
      float ix2 = ix + seed * 131.0;
      float iy2 = iy + seed * 71.0;
      float rnd = hash2(ix2, iy2);
      float ox = hash2(ix2 + 91.0, iy2 + 7.0);
      float oy = hash2(ix2 + 13.0, iy2 + 57.0);
      float fx = (g.x - ix - ox) * cell;
      float fy = (g.y - iy - oy) * cell;
      float d2 = fx * fx + fy * fy;
      float mag = hash2(ix2 + 5.0, iy2 + 11.0);
      float size = sizeLo + (sizeHi - sizeLo) * mag * mag * mag * mag;
      float val;
      if (soft) {
        float sigma = size * 1.8 + 0.6;
        val = exp(-d2 / (2.0 * sigma * sigma)) *
              (size * size) / (sigma * sigma) * 2.4;
      } else {
        val = exp(-d2 / (2.0 * size * size));
      }
      float tw = 0.78 + 0.22 * sin(T * (1.1 + 2.3 * mag) + rnd * 40.0);
      float lum = (0.25 + 0.75 * mag * mag) * tw;
      total += (rnd < prob) ? val * lum : 0.0;
      if (i == 0 && j == 0) gold = hash2(ix2 + 3.0, iy2 + 29.0);
    }
  }
  return vec2(total, gold);
}

// Orbiting stars: polar cells; rings of width `cell` rotate rigidly at
// omegaOf(ring), so stars keep their shape while inner rings run faster.
float diskStarLayer(float rpx, float th, vec2 px, float cell, float prob,
                    float sizeLo, float sizeHi, bool soft, float seed,
                    float S, float T, float ca, float sa, vec2 core) {
  float total = 0.0;
  float k0 = floor(rpx / cell);
  for (int dk = -1; dk <= 1; dk++) {
    float k = max(k0 + float(dk), 0.0);
    float n = max(6.0, floor(TAU * (k + 0.5)));
    float rRing = (k + 0.5) * cell;
    float rot = omegaOf(rRing, S) * T;
    float phi = mod(th - rot, TAU);
    float j0 = floor(phi / TAU * n);
    for (int dj = -1; dj <= 1; dj++) {
      float j = mod(j0 + float(dj), n);
      float hx = k * 977.0 + seed * 131.0;
      float hy = j + seed * 71.0;
      float rnd = hash2(hx, hy);
      float jr = hash2(hx + 91.0, hy + 7.0);
      float jp = hash2(hx + 13.0, hy + 57.0);
      float sr = (k + jr) * cell;
      float sp = (j + jp) / n * TAU + rot;
      // to_screen(sr cos sp, sr sin sp): dv *= incl, then rotate by tilt.
      float du = sr * cos(sp);
      float dv = sr * sin(sp) * INCL;
      vec2 sxy = vec2(core.x + du * ca - dv * sa,
                      core.y + du * sa + dv * ca);
      vec2 dd = sxy - px;
      float d2 = dot(dd, dd);
      float mag = hash2(hx + 5.0, hy + 11.0);
      float size = sizeLo + (sizeHi - sizeLo) * mag * mag * mag * mag;
      float val;
      if (soft) {
        float sigma = size * 1.8 + 0.6;
        val = exp(-d2 / (2.0 * sigma * sigma)) *
              (size * size) / (sigma * sigma) * 2.4;
      } else {
        val = exp(-d2 / (2.0 * size * size));
      }
      float lum = 0.25 + 0.75 * mag * mag;
      total += (rnd < prob) ? val * lum : 0.0;
    }
  }
  return total;
}

vec3 galaxy(vec2 pg, vec2 pbg, bool soft) {
  float m = max(u_size.x, u_size.y);
  vec2 core = vec2(CORE_X * u_size.x, CORE_Y * u_size.y);
  float a = radians(TILT);
  vec2 d = pg - core;
  float ca = cos(a), sa = sin(a);
  float u = d.x * ca + d.y * sa;
  float v = (-d.x * sa + d.y * ca) / INCL;
  float S = SCALE * m;
  float r = length(vec2(u, v)) / S;
  float th = atan(v, u);

  float omegaP = TAU / 1800.0;
  float omega = omegaOf(r * S, S);
  float warp = WARP * (fbm(u / S * 3.0 + 5.0, v / S * 3.0, 3) - 0.5);
  float phase = th - WIND * log(r + 0.02) - omegaP * u_time + warp;
  float arm = pow(0.5 + 0.5 * cos(2.0 * phase), SHARP);
  float dust = pow(0.5 + 0.5 * cos(2.0 * (phase - 0.40)),
                   soft ? 8.0 : DUST_POW);

  // Clouds turn rigidly with the arm pattern (differential rotation
  // would wind them into rings); orbiting stars carry the inner-faster
  // motion in diskStarLayer.
  float texTh = th - omegaP * u_time;
  vec2 tuv = vec2(r * cos(texTh), r * sin(texTh));
  float clump;
  if (soft) {
    clump = fbm(tuv.x * 8.0 + 1.3, tuv.y * 8.0 + 7.1, 2);
    clump = 0.40 + 1.2 * clump * clump;
  } else {
    clump = fbm(tuv.x * CLUMP_FREQ + 1.3, tuv.y * CLUMP_FREQ + 7.1, 5);
    clump = CLUMP_LO + CLUMP_HI * clump * clump;
  }

  float inner = clamp((r - 0.03) / 0.10, 0.0, 1.0);
  float env = exp(-r / ENV) * inner;
  float armd = env * (0.08 + 0.92 * arm);
  float arms = ARM_GAIN * armd * clump * (soft ? 1.0 : NEB);
  arms *= 1.0 - DUST * dust * clamp(env * 3.0, 0.0, 1.0);
  float bulge = BULGE * exp(-pow(r / BULGE_R, 2.0)) +
                0.30 * exp(-r / (BULGE_R * 2.4));
  float halo = HALO * exp(-r / HALO_R);

  vec3 ice = vec3(0.78, 0.86, 1.00);
  vec3 lav = vec3(0.66, 0.60, 1.00);
  vec3 warm = vec3(1.00, 0.91, 0.78);
  vec3 haloC = vec3(0.50, 0.47, 0.96);
  float outer = pow(clamp((r - 0.25) / 0.75, 0.0, 1.0), 1.5);
  vec3 armC = ice * (1.0 - outer) + lav * outer;
  vec3 col = arms * armC + bulge * warm + halo * haloC;

  float densityArm = clamp(armd * 4.0 + bulge * 0.6, 0.0, 1.0);
  if (soft) {
    float glow = ARM_GAIN * 0.55 * env * (0.15 + 0.85 * pow(arm, 0.6));
    col += glow * (0.55 * ice + 0.45 * lav);
    float grain = diskStarLayer(r * S, th, pg, 8.0, 0.75, 0.5, 1.1, true,
                                1.0, S, u_time, ca, sa, core);
    col += grain * densityArm * ice * 0.45 * GRAIN;
  } else {
    float grain = diskStarLayer(r * S, th, pg, GRAIN_CELL, GRAIN_PROB,
                                GRAIN_LO, GRAIN_HI, false, 1.0, S, u_time,
                                ca, sa, core);
    col += grain * densityArm * ice * GRAIN_GAIN * GRAIN;
  }
  float knotW = clamp((arm - 0.45) / 0.4, 0.0, 1.0) *
                clamp(env / 0.08, 0.0, 1.0);
  float knots = diskStarLayer(r * S, th, pg, soft ? 16.0 : 12.0, 0.12, 1.0,
                              2.4, soft, 2.0, S, u_time, ca, sa, core);
  col += knots * knotW * vec3(0.88, 0.70, 1.00) *
         (soft ? 0.68 : 0.9) * KNOTS;

  vec2 bg = starLayer(pbg, 13.0, (soft ? 0.10 : BG_PROB) * BG_STARS, 0.30,
                      soft ? 1.5 : BG_HI, soft, 3.0, u_time);
  vec3 goldC = (bg.y < 0.05) ? vec3(1.0, 0.84, 0.50) : vec3(0.92, 0.94, 1.0);
  col += bg.x * goldC * (soft ? 0.40 : 1.0);
  if (!soft) {
    vec2 bg2 = starLayer(pbg, BG2_CELL, BG2_PROB, BG2_LO, BG2_HI, false, 7.0,
                         u_time);
    vec3 gold2C = (bg2.y < BG2_GOLD) ? vec3(1.0, 0.84, 0.50)
                                     : vec3(0.90, 0.93, 1.0);
    col += bg2.x * gold2C * BG2_GAIN;
  }
  return col;
}

float rectSdf(vec2 px, vec4 rect, float radius) {
  vec2 c = (rect.xy + rect.zw) * 0.5;
  vec2 b = (rect.zw - rect.xy) * 0.5;
  vec2 q = abs(px - c) - b + vec2(radius);
  return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
}

float pointerF(vec2 px, vec4 slot) {
  vec2 d = px - slot.xy;
  float d2 = dot(d, d);
  float dist = sqrt(d2);
  return slot.z * exp(-d2 / (2.0 * 60.0 * 60.0)) *
         (1.0 - smoothstep(100.0, 120.0, dist));
}

void main() {
  vec2 frag = FlutterFragCoord().xy;
  vec2 px = frag;

  // Pointer trail: displace the sample outward from each slot and brighten.
  vec2 displace = vec2(0.0);
  float fs = 0.0;
  for (int i = 0; i < 6; i++) {
    vec4 slot = i == 0 ? u_trail0
              : i == 1 ? u_trail1
              : i == 2 ? u_trail2
              : i == 3 ? u_trail3
              : i == 4 ? u_trail4
                       : u_trail5;
    if (slot.z <= 0.001) continue;
    float f = pointerF(px, slot);
    vec2 dd = px - slot.xy;
    float dist = length(dd);
    if (dist > 0.5) displace += 18.0 * f * dd / dist;
    fs += f;
  }
  // Cap the summed displacement at 18 pt and the brightening at +60%.
  float dl = length(displace);
  if (dl > 18.0) displace *= 18.0 / dl;
  fs = min(fs, 1.0);

  vec2 pg = px - u_parallax.xy * 0.012 - displace;
  vec2 pbg = px - u_parallax.xy * 0.004;

  // Glass coverage in logical points (rounded-rect SDF, real pane radius).
  bool inside = false;
  if (u_glassCount > 0.5 &&
      rectSdf(px, u_glass0, u_glassRadius.x) <= 0.0) inside = true;
  if (u_glassCount > 1.5 &&
      rectSdf(px, u_glass1, u_glassRadius.y) <= 0.0) inside = true;
  if (u_glassCount > 2.5 &&
      rectSdf(px, u_glass2, u_glassRadius.z) <= 0.0) inside = true;
  if (u_glassCount > 3.5 &&
      rectSdf(px, u_glass3, u_glassRadius.w) <= 0.0) inside = true;

  vec3 col = inside ? galaxy(pg, pbg, true) * GLASS_GAIN
                    : galaxy(pg, pbg, false);
  col *= 1.0 + 0.6 * fs;

  col = vec3(1.0) - exp(-col * EXPOSURE);
  vec3 base = vec3(0x06, 0x06, 0x09) / 255.0;
  col = base + (vec3(1.0) - base) * col;
  if (inside) {
    // Smoke glass transfer: dim sky sinks to the pane smoke, bright light
    // keeps most of its energy (frosted glass scatters it).
    vec3 pane = vec3(0x0C, 0x0C, 0x11) / 255.0;
    vec3 g = pow(clamp(col, vec3(0.0), vec3(1.0)),
                 vec3(GLASS_GAMMA)) * GLASS_KEEP;
    // Soft luminance ceiling: above the knee the light rolls off towards
    // GLASS_CEIL, so the core glows through a pane but never becomes a white
    // field behind its content. Hue is kept by scaling all channels.
    float lum = dot(g, vec3(0.2126, 0.7152, 0.0722));
    if (lum > GLASS_KNEE) {
      float over = lum - GLASS_KNEE;
      float rolled = GLASS_KNEE +
          over / (1.0 + over / (GLASS_CEIL - GLASS_KNEE));
      g *= rolled / lum;
    }
    col = pane + (vec3(1.0) - pane) * g;
  }
  fragColor = vec4(clamp(col, vec3(0.0), vec3(1.0)), 1.0);
}
