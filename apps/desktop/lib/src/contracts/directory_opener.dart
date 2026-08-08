final class DirectoryOpenResult {
  const DirectoryOpenResult({required this.exitCode});

  final int exitCode;
}

/// Platform operation required to reveal a user-selected directory.
abstract interface class DirectoryOpener {
  Future<DirectoryOpenResult> openDirectory(String directoryPath);
}
