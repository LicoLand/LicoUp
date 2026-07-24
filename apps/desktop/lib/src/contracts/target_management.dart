import 'package:licoup/src/contracts/target_candidate.dart';

/// Narrow native boundary used by target discovery and configuration.
abstract interface class TargetManagementGateway {
  Future<TargetCandidate?> scanOneTarget(String targetId);

  Future<Map<String, dynamic>> addTarget({
    required String target,
    String configPath = '',
    String binaryPath = '',
    String historyRoot = '',
  });

  Future<Map<String, dynamic>> inspectTarget(String target);

  Future<Map<String, dynamic>> restoreSnapshot(String snapshotId);
}

/// Durable cache boundary for the last visible target snapshot.
abstract interface class TargetSnapshotRepository {
  Future<List<TargetCandidate>> load(Object portableData);

  Future<void> save(Object portableData, List<TargetCandidate> targets);
}

/// Durable ordering boundary for conversation target tabs.
abstract interface class TargetTabOrderRepository {
  Future<List<String>> load(Object portableData);

  Future<void> save(Object portableData, List<String> order);
}
