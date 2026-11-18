import 'package:licoup/src/application/features/targets/policy/target_policy.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/contracts/target_management.dart';

/// Immutable state transition produced by one completed target scan.
final class TargetScanReduction {
  const TargetScanReduction({
    required this.targets,
    required this.successfulSlots,
    required this.failedTargetIds,
    required this.discoveredCount,
  });

  final List<TargetCandidate> targets;
  final List<TargetScanSlot> successfulSlots;
  final List<String> failedTargetIds;
  final int discoveredCount;
}

/// Pure reducer for target discovery results.
///
/// A missing or failed response slot preserves the latest visible snapshot.
/// Successful slots alone may add, update, or remove their own target.
final class TargetScanReducer {
  const TargetScanReducer._();

  static TargetScanReduction reduce({
    required List<TargetCandidate> currentTargets,
    required Iterable<String> requestedTargetIds,
    required TargetScanBatch batch,
    required bool replaceModelCatalog,
  }) {
    final slotsById = <String, TargetScanSlot>{};
    for (final slot in batch.slots) {
      final id = slot.targetId.trim();
      if (id.isNotEmpty) slotsById[id] = slot;
    }
    final requested = <String>[];
    final seen = <String>{};
    for (final targetId in requestedTargetIds) {
      final id = targetId.trim();
      if (id.isNotEmpty && seen.add(id)) requested.add(id);
    }

    final knownIds = currentTargets.map((target) => target.target).toSet();
    final successful = <TargetScanSlot>[];
    final failed = <String>[];
    var discovered = 0;
    var next = currentTargets;
    for (final targetId in requested) {
      final slot = slotsById[targetId];
      if (slot == null || slot.failed) {
        failed.add(targetId);
        continue;
      }
      successful.add(slot);
      final candidate = slot.candidate;
      if (candidate != null && !knownIds.contains(candidate.target)) {
        discovered += 1;
      }
      next = TargetPolicy.mergeProbe(
        next,
        targetId,
        candidate,
        replaceModelCatalog: replaceModelCatalog,
      );
    }

    return TargetScanReduction(
      targets: List.unmodifiable(next),
      successfulSlots: List.unmodifiable(successful),
      failedTargetIds: List.unmodifiable(failed),
      discoveredCount: discovered,
    );
  }
}
