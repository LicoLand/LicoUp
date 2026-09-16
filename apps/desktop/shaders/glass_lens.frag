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
  vec2 q = abs(p) - b + vec2(r);
  vec2 corner = max(q, 0.0);
  float len = length(corner);
  if (len > 0.0001) {
    return sign(p) * corner / len;
  }
  return q.x > q.y ? vec2(sign(p.x), 0.0) : vec2(0.0, sign(p.y));
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
  // Keep the optical body at the perimeter, even on a short search field.
  // Displacement strength must not enlarge the affected band across the face.
  float band = max(1.0, min(min(u_size.x, u_size.y) * 0.25, 12.0));
  float rim = smoothstep(-band, 0.0, dist);
  rim *= rim;
  // A convex slab magnifies the backdrop by sampling toward its interior.
  vec2 offset = -normal * u_displace * rim;

  if (u_chroma <= 0.0001) {
    frag_color = texture(u_texture, sampleUv(frag, offset));
    return;
  }
  vec4 cr = texture(u_texture, sampleUv(frag, offset * (1.0 + u_chroma)));
  vec4 cg = texture(u_texture, sampleUv(frag, offset));
  vec4 cb = texture(u_texture, sampleUv(frag, offset * (1.0 - u_chroma)));
  frag_color = vec4(cr.r, cg.g, cb.b, cg.a);
}
