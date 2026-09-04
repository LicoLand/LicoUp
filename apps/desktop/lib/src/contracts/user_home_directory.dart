import 'dart:io' as io show Platform;

/// Resolves the current user's home directory for local presentation and
/// filesystem policy without coupling either layer to the other.
String userHomeDirectory({Map<String, String>? environment}) {
  final resolved = environment ?? io.Platform.environment;
  return (resolved['HOME'] ?? resolved['USERPROFILE'] ?? '').trim();
}
