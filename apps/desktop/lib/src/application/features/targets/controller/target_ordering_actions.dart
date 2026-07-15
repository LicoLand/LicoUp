part of 'package:flutter_client/src/application/controller/client_controller.dart';

extension ClientTargetOrderingActions on ClientController {
  List<TargetCandidate> orderedConversationTargets(
    Iterable<TargetCandidate> targets,
  ) {
    final visibleTargets = targets
        .where((target) => target.isConversationAgent)
        .where((target) => !isAgentOrchestrationTargetId(target.target))
        .toList(growable: false);
    final orderedTargets = _orderedRealConversationTargets(visibleTargets);
    if (_mobileClientRuntimePlatform || !routingModuleAvailable) {
      return orderedTargets;
    }
    return List.unmodifiable([
      agentOrchestrationTargetCandidate(label: _strings.defaultLabel),
      ...orderedTargets,
    ]);
  }

  List<TargetCandidate> _orderedRealConversationTargets(
    List<TargetCandidate> visibleTargets,
  ) {
    if (visibleTargets.isEmpty || agentTabOrder.isEmpty) {
      return visibleTargets;
    }
    final byId = {for (final target in visibleTargets) target.target: target};
    final ordered = <TargetCandidate>[];
    final used = <String>{};
    for (final targetId in agentTabOrder) {
      final target = byId[targetId];
      if (target != null && used.add(target.target)) {
        ordered.add(target);
      }
    }
    for (final target in visibleTargets) {
      if (used.add(target.target)) {
        ordered.add(target);
      }
    }
    return List.unmodifiable(ordered);
  }

  Future<void> reorderConversationAgentTabs(
    List<TargetCandidate> visibleTargets,
    int oldIndex,
    int newIndex,
  ) async {
    if (oldIndex < 0 ||
        oldIndex >= visibleTargets.length ||
        isAgentOrchestrationTargetId(visibleTargets[oldIndex].target)) {
      return;
    }
    final ordered = visibleTargets
        .where((target) => target.isConversationAgent)
        .where((target) => !isAgentOrchestrationTargetId(target.target))
        .toList(growable: true);
    final movedTargetId = visibleTargets[oldIndex].target;
    final oldRealIndex = ordered.indexWhere(
      (target) => target.target == movedTargetId,
    );
    final insertionTargetIndex = newIndex >= visibleTargets.length
        ? ordered.length
        : ordered.indexWhere(
            (target) => target.target == visibleTargets[newIndex].target,
          );
    final newRealIndex = insertionTargetIndex < 0
        ? ordered.length
        : insertionTargetIndex;
    if (oldIndex < 0 ||
        oldRealIndex < 0 ||
        newIndex < 0 ||
        newRealIndex > ordered.length ||
        oldIndex == newIndex) {
      return;
    }
    final moved = ordered.removeAt(oldRealIndex);
    ordered.insert(newRealIndex.clamp(0, ordered.length).toInt(), moved);
    final visibleIds = ordered.map((target) => target.target).toSet();
    agentTabOrder = List.unmodifiable([
      for (final target in ordered) target.target,
      for (final targetId in agentTabOrder)
        if (!visibleIds.contains(targetId)) targetId,
    ]);
    _notifyStateChanged();
    try {
      await agentTabOrderStore.save(portableData, agentTabOrder);
    } catch (error) {
      debugPrint('Failed to persist agent tab order: $error');
      lastError = error.toString();
      _setLocalizedStatusMessage(
        '智能体标签页顺序保存失败。',
        'Failed to save the agent tab order.',
      );
      statusCaption = 'Agent tabs';
      _notifyStateChanged();
    }
  }
}
