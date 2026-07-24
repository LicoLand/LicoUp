import 'package:licoup/src/contracts/catalog_convergence/catalog_convergence_models.dart';

abstract interface class CatalogConvergenceGateway {
  Future<CatalogConvergenceStatus> status();

  Future<void> beginReconnect();

  Future<List<String>> invalidate(CatalogInvalidation notification);

  Future<void> replacePartition(
    String partitionKey,
    CatalogFetchedSnapshot snapshot,
  );

  Future<CatalogDiscoveryResult> listTools(String partitionKey);

  Future<bool> observeUi(String partitionKey);

  Future<void> purge({String partitionKey = ''});
}

typedef CatalogAuthenticatedPull =
    Future<CatalogFetchedSnapshot> Function(String opaquePartitionKey);
