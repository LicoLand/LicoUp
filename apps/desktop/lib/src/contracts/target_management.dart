import 'package:licoup/src/contracts/target_candidate.dart';

/// Narrow native boundary used by target discovery and configuration.
abstract interface class TargetManagementGateway {
  Future<TargetScanBatch> scanTargetsBatch(
    List<String> targetIds, {
    bool enableAgentCliModelLookup = false,
  });

  Future<Map<String, dynamic>> addTarget({
    required String target,
    String configPath = '',
    String binaryPath = '',
    String historyRoot = '',
    String location = 'local',
    Map<String, dynamic> runtimeConnection = const <String, dynamic>{},
  });

  Future<Map<String, dynamic>> inspectTarget(String target);

  Future<Map<String, dynamic>> restoreSnapshot(String snapshotId);
}

final class TargetScanBatch {
  const TargetScanBatch(this.slots);

  final List<TargetScanSlot> slots;
}

final class TargetScanSlot {
  const TargetScanSlot({
    required this.targetId,
    this.candidate,
    this.failed = false,
  });

  final String targetId;
  final TargetCandidate? candidate;
  final bool failed;
}

/// Durable cache boundary for the last visible target snapshot.
abstract interface class TargetSnapshotRepository {
  Future<List<TargetCandidate>> load(Object portableData);

  Future<void> save(Object portableData, List<TargetCandidate> targets);
}

/// Durable ordering and pin boundary for conversation target tabs/contacts.
abstract interface class TargetTabOrderRepository {
  Future<List<String>> load(Object portableData);

  Future<void> save(Object portableData, List<String> order);

  Future<List<String>> loadPinned(Object portableData);

  Future<void> savePinned(Object portableData, List<String> pinned);

  /// True when the store has an explicit pin document (including an empty list).
  Future<bool> hasCustomPinnedIds(Object portableData);
}
