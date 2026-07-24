import 'package:licoup/src/contracts/target_candidate.dart';

class TargetPolicy {
  const TargetPolicy._();

  static List<String> incrementalScanIds({
    required Iterable<String> packagedIds,
    required Iterable<TargetCandidate> currentTargets,
    required bool rescanKnown,
  }) {
    final known = currentTargets
        .map((target) => target.target.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    return List.unmodifiable(
      packagedIds
          .map((id) => id.trim())
          .where((id) => id.isNotEmpty)
          .where((id) => rescanKnown || !known.contains(id)),
    );
  }

  static List<TargetCandidate> mergeProbe(
    List<TargetCandidate> current,
    String targetId,
    TargetCandidate? candidate,
  ) {
    final id = targetId.trim();
    if (candidate == null) {
      return List.unmodifiable(
        current.where((target) => target.target.trim() != id),
      );
    }
    final next = List<TargetCandidate>.from(current);
    final index = next.indexWhere(
      (target) => target.target.trim() == candidate.target.trim(),
    );
    if (index < 0) {
      next.add(candidate);
    } else {
      next[index] = candidate;
    }
    return List.unmodifiable(next);
  }

  static List<TargetCandidate> mobileRelayTargets(Map<String, dynamic> status) {
    final targets =
        ((status['pairing'] as Map?)?['pc'] as Map?)?['targets'] as List?;
    if (targets == null) return const [];
    return List.unmodifiable(
      targets
          .whereType<Map>()
          .map(
            (item) => TargetCandidate.fromJson(Map<String, dynamic>.from(item)),
          )
          .where((target) => target.visibleInClient && target.canRelayRuntime),
    );
  }

  static List<TargetCandidate> orderedConversationTargets({
    required Iterable<TargetCandidate> targets,
    required Iterable<String> persistedOrder,
    required bool Function(String targetId) isOrchestrationTarget,
    TargetCandidate? orchestrationTarget,
  }) {
    final visible = targets
        .where((target) => target.isConversationAgent)
        .where((target) => !isOrchestrationTarget(target.target))
        .toList(growable: false);
    final order = persistedOrder.toList(growable: false);
    final byId = {for (final target in visible) target.target: target};
    final used = <String>{};
    final ordered = <TargetCandidate>[
      for (final id in order)
        if (byId[id] case final target? when used.add(target.target)) target,
      for (final target in visible)
        if (used.add(target.target)) target,
    ];
    return List.unmodifiable([?orchestrationTarget, ...ordered]);
  }

  static List<String>? reorderedTabIds({
    required List<TargetCandidate> visibleTargets,
    required List<String> persistedOrder,
    required int oldIndex,
    required int newIndex,
    required bool Function(String targetId) isOrchestrationTarget,
  }) {
    if (oldIndex < 0 ||
        oldIndex >= visibleTargets.length ||
        newIndex < 0 ||
        isOrchestrationTarget(visibleTargets[oldIndex].target) ||
        oldIndex == newIndex) {
      return null;
    }
    final realTargets = visibleTargets
        .where((target) => target.isConversationAgent)
        .where((target) => !isOrchestrationTarget(target.target))
        .toList(growable: true);
    final movedId = visibleTargets[oldIndex].target;
    final oldRealIndex = realTargets.indexWhere(
      (target) => target.target == movedId,
    );
    final insertionIndex = newIndex >= visibleTargets.length
        ? realTargets.length
        : realTargets.indexWhere(
            (target) => target.target == visibleTargets[newIndex].target,
          );
    final newRealIndex = insertionIndex < 0
        ? realTargets.length
        : insertionIndex;
    if (oldRealIndex < 0 || newRealIndex > realTargets.length) return null;
    final moved = realTargets.removeAt(oldRealIndex);
    realTargets.insert(newRealIndex.clamp(0, realTargets.length), moved);
    final visibleIds = realTargets.map((target) => target.target).toSet();
    return List.unmodifiable([
      for (final target in realTargets) target.target,
      for (final id in persistedOrder)
        if (!visibleIds.contains(id)) id,
    ]);
  }
}
