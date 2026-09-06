typedef PlanDocumentLoader = Future<String> Function(String path);

Future<String> unavailablePlanDocumentLoader(String path) async => '';
