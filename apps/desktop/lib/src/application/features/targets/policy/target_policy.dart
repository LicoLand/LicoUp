import 'package:licoup/src/contracts/target_candidate.dart';

class TargetPolicy {
  const TargetPolicy._();

  /// Default pin set for conversation contacts/tabs.
  static const List<String> defaultPinnedConversationTargetIds = [];

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
    TargetCandidate? candidate, {
    bool replaceModelCatalog = true,
  }) {
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
    var incoming = candidate;
    if (!replaceModelCatalog &&
        index >= 0 &&
        hasSelectedAgentModelCatalog(next[index]) &&
        !hasSelectedAgentModelCatalog(incoming)) {
      incoming = incoming.withModelCatalog(next[index].modelCatalog);
    }
    if (index < 0) {
      next.add(incoming);
    } else {
      next[index] = incoming;
    }
    return List.unmodifiable(next);
  }

  /// Catalog sources that exist only after the user opens that Agent's
  /// conversation interface: native CLI lookup or another app's named store.
  static bool hasSelectedAgentModelCatalog(TargetCandidate target) {
    final sources = target.modelCatalog['sources'];
    if (sources is! List) {
      return false;
    }
    const selected = {
      'cursor-cli',
      'antigravity-cli',
      'antigravity-local',
      'kilo-cli',
      'claude-cli',
      'codex-app-server',
      'pi-cli:list-models',
    };
    return sources.any((source) => selected.contains(source.toString()));
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

  /// Resolves the effective pin list. Until the user customizes pins, the
  /// product defaults stay pinned.
  static List<String> effectivePinnedConversationTargetIds({
    required Iterable<String> persistedPinnedIds,
    bool pinsInitialized = false,
  }) {
    if (!pinsInitialized) {
      return List.unmodifiable(defaultPinnedConversationTargetIds);
    }
    return List.unmodifiable([
      for (final id in persistedPinnedIds)
        if (id.trim().isNotEmpty) id.trim(),
    ]);
  }

  static List<TargetCandidate> orderedConversationTargets({
    required Iterable<TargetCandidate> targets,
    required Iterable<String> persistedOrder,
    Iterable<String> pinnedIds = const [],
  }) {
    final visible = targets
        .where((target) => target.isConversationAgent)
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
    return List.unmodifiable(
      pinOrderedConversationTargets(targets: ordered, pinnedIds: pinnedIds),
    );
  }

  /// Sorts [targets] with pinned ids first (in pin order), then unpinned in
  /// their incoming relative order.
  static List<TargetCandidate> pinOrderedConversationTargets({
    required Iterable<TargetCandidate> targets,
    required Iterable<String> pinnedIds,
  }) {
    final list = targets.toList(growable: false);
    if (list.isEmpty) {
      return const [];
    }
    final byId = <String, TargetCandidate>{
      for (final target in list) target.target: target,
    };
    final pinned = <TargetCandidate>[];
    final pinnedUsed = <String>{};
    for (final id in pinnedIds) {
      final target = byId[id.trim()];
      if (target != null && pinnedUsed.add(target.target)) {
        pinned.add(target);
      }
    }
    final unpinned = [
      for (final target in list)
        if (!pinnedUsed.contains(target.target)) target,
    ];
    return List.unmodifiable([...pinned, ...unpinned]);
  }

  static List<String>? reorderedTabIds({
    required List<TargetCandidate> visibleTargets,
    required List<String> persistedOrder,
    required int oldIndex,
    required int newIndex,
  }) {
    if (oldIndex < 0 ||
        oldIndex >= visibleTargets.length ||
        newIndex < 0 ||
        oldIndex == newIndex) {
      return null;
    }
    final realTargets = visibleTargets
        .where((target) => target.isConversationAgent)
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
