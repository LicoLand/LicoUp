#include <flutter/runtime_effect.glsl>

// Impeller ImageFilter.shader: engine sets u_size and u_texture.
// Extra floats must follow the vec2 size uniform without padding.
uniform vec2 u_size;
uniform float u_radius;
uniform float u_displace;
uniform float u_chroma;
uniform sampler2D u_texture;

out vec4 frag_color;

float roundedBoxSdf(vec2 p, vec2 b, float r) {
  vec2 q = abs(p) - b + vec2(r);
  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

vec2 roundedBoxNormal(vec2 p, vec2 b, float r) {
  float e = 1.0;
  float dx = roundedBoxSdf(p + vec2(e, 0.0), b, r) -
      roundedBoxSdf(p - vec2(e, 0.0), b, r);
  float dy = roundedBoxSdf(p + vec2(0.0, e), b, r) -
      roundedBoxSdf(p - vec2(0.0, e), b, r);
  vec2 n = vec2(dx, dy);
  float len = length(n);
  return len > 0.0001 ? n / len : vec2(0.0);
}

vec2 sampleUv(vec2 frag, vec2 offset) {
  vec2 uv = (frag + offset) / u_size;
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif
  return clamp(uv, 0.0, 1.0);
}

void main() {
  vec2 frag = FlutterFragCoord().xy;
  vec2 center = u_size * 0.5;
  vec2 p = frag - center;
  float radius = max(0.0, min(u_radius, min(center.x, center.y)));
  vec2 halfSize = max(center, vec2(0.5));
  float dist = roundedBoxSdf(p, halfSize, radius);
  vec2 normal = roundedBoxNormal(p, halfSize, radius);
  // Stronger at the rim, weaker toward the face — long capsules bend on
  // the flat sides instead of smearing toward the center.
  float rim = 1.0 - smoothstep(-max(u_displace * 6.0, 1.0), 0.0, dist);
  vec2 offset = normal * u_displace * rim;

  if (u_chroma <= 0.0001) {
    frag_color = texture(u_texture, sampleUv(frag, offset));
    return;
  }
  vec4 cr = texture(u_texture, sampleUv(frag, offset * (1.0 + u_chroma)));
  vec4 cg = texture(u_texture, sampleUv(frag, offset));
  vec4 cb = texture(u_texture, sampleUv(frag, offset * (1.0 - u_chroma)));
  frag_color = vec4(cr.r, cg.g, cb.b, cg.a);
}
