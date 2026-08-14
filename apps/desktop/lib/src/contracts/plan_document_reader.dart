abstract interface class PlanDocumentReader {
  Future<String> read(String path);
}

/// Safe presentation fallback for panes that never bind a plan document.
final class UnavailablePlanDocumentReader implements PlanDocumentReader {
  const UnavailablePlanDocumentReader();

  @override
  Future<String> read(String path) async => '';
}
