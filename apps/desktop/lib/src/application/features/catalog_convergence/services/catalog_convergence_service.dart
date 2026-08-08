import 'package:licoup/src/contracts/catalog_convergence/catalog_convergence_gateway.dart';
import 'package:licoup/src/contracts/catalog_convergence/catalog_convergence_models.dart';
import 'package:licoup/src/platform/native_client/agent_service.dart';

final class CatalogConvergenceService implements CatalogConvergenceGateway {
  const CatalogConvergenceService({required AgentService agentService})
    : _agentService = agentService;

  final AgentService _agentService;

  @override
  Future<CatalogConvergenceStatus> status() async {
    final result = await _agentService.runCatalogCommand('status');
    return CatalogConvergenceStatus.fromJson(result);
  }

  @override
  Future<void> beginReconnect() async {
    await _agentService.runCatalogCommand('reconnect');
  }

  @override
  Future<List<String>> invalidate(CatalogInvalidation notification) async {
    final result = await _agentService.runCatalogCommand(
      'invalidate',
      params: notification.toJson(),
    );
    final keys = result['acceptedPartitionKeys'];
    if (keys is! List || keys.length > catalogConvergenceMaxPartitions) {
      throw const FormatException('catalog_invalidation_result_invalid');
    }
    return List<String>.unmodifiable(
      keys.map((key) {
        if (key is! String || key.trim().isEmpty) {
          throw const FormatException('catalog_invalidation_result_invalid');
        }
        return key.trim();
      }),
    );
  }

  @override
  Future<void> replacePartition(
    String partitionKey,
    CatalogFetchedSnapshot snapshot,
  ) async {
    final result = await _agentService.runCatalogCommand(
      'refresh',
      params: snapshot.toJson(partitionKey),
    );
    if (result['outcome'] != 'replaced' && result['outcome'] != 'unchanged') {
      throw const FormatException('catalog_refresh_rejected');
    }
  }

  @override
  Future<CatalogDiscoveryResult> listTools(String partitionKey) async {
    final result = await _agentService.runCatalogCommand(
      'list',
      params: {'partitionKey': partitionKey.trim()},
    );
    return CatalogDiscoveryResult.fromJson(result);
  }

  @override
  Future<bool> observeUi(String partitionKey) async {
    final result = await _agentService.runCatalogCommand(
      'observe',
      params: {'partitionKey': partitionKey.trim()},
    );
    return result['observed'] == true;
  }

  @override
  Future<void> purge({String partitionKey = ''}) async {
    await _agentService.runCatalogCommand(
      'purge',
      params: {
        if (partitionKey.trim().isNotEmpty) 'partitionKey': partitionKey.trim(),
      },
    );
  }
}
