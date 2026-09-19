import 'dart:ui';

/// Cached Impeller fragment program for glass rim displacement.
///
/// [ImageFilter.shader] is Impeller-only. Callers must fall back to blur
/// plus a specular rim when this loader returns null.
abstract final class GlassLens {
  static const asset = 'shaders/glass_lens.frag';

  static FragmentProgram? _program;
  static Future<void>? _loading;
  static bool _failed = false;

  static bool get isSupported {
    try {
      return ImageFilter.isShaderFilterSupported;
    } catch (_) {
      return false;
    }
  }

  static bool get isLoaded => _program != null;

  static Future<void> ensureLoaded() {
    if (_program != null || _failed || !isSupported) {
      return Future<void>.value();
    }
    return _loading ??= () async {
      try {
        _program = await FragmentProgram.fromAsset(asset);
      } catch (_) {
        _failed = true;
      }
    }();
  }

  /// Displacement filter for a finite glass rect. Returns null when the
  /// shader is unavailable or [size] is not finite.
  static ImageFilter? createFilter({
    required Size size,
    required double radius,
    double displace = 8,
    double chroma = 0,
  }) {
    final program = _program;
    if (program == null ||
        !size.isFinite ||
        size.width <= 0 ||
        size.height <= 0) {
      return null;
    }
    final shader = program.fragmentShader();
    // u_size occupies float indices 0 and 1 (engine-owned).
    shader.setFloat(2, radius);
    shader.setFloat(3, displace);
    shader.setFloat(4, chroma);
    try {
      return ImageFilter.shader(shader);
    } catch (_) {
      return null;
    }
  }
}
