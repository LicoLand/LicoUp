import 'dart:io' as io show Platform;

/// Resolves the current user's home directory for filesystem policy.
String userHomeDirectory({Map<String, String>? environment}) {
  final resolved = environment ?? io.Platform.environment;
  return (resolved['HOME'] ?? resolved['USERPROFILE'] ?? '').trim();
}
