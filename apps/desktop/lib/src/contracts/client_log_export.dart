final class ClientLogExportResult {
  const ClientLogExportResult({
    required this.path,
    required this.bytes,
    required this.sourceExists,
  });

  final String path;
  final int bytes;
  final bool sourceExists;
}

/// Narrow application port for exporting the bounded client activity log.
abstract interface class ClientLogExporter {
  Future<ClientLogExportResult> exportLogs({
    required Object portableData,
    required String destinationPath,
  });
}
