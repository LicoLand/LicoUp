part of 'package:flutter_client/src/application/controller/client_controller.dart';

extension ClientMobileHomeLayoutActions on ClientController {
  Future<void> reorderMobileHomePinnedEntries(
    List<String> pinnedEntryIds,
    int oldIndex,
    int newIndex,
  ) async {
    final pinned = pinnedEntryIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toList(growable: true);
    if (oldIndex < 0 ||
        oldIndex >= pinned.length ||
        newIndex < 0 ||
        newIndex > pinned.length ||
        oldIndex == newIndex) {
      return;
    }
    var insertIndex = newIndex;
    if (oldIndex < insertIndex) {
      insertIndex -= 1;
    }
    if (oldIndex == insertIndex) {
      return;
    }
    final moved = pinned.removeAt(oldIndex);
    pinned.insert(insertIndex.clamp(0, pinned.length).toInt(), moved);
    final pinnedSet = pinned.toSet();
    mobileHomeLayout = mobileHomeLayout.copyWith(
      order: [
        ...pinned,
        for (final id in mobileHomeLayout.order)
          if (!pinnedSet.contains(id)) id,
      ],
    );
    _notifyStateChanged();
    await mobileHomeLayoutService.save(portableData, mobileHomeLayout);
  }

  Future<void> toggleMobileHomeEntryPinned(String entryId) async {
    final normalized = entryId.trim();
    if (normalized.isEmpty) {
      return;
    }
    final pinned = Set<String>.from(mobileHomeLayout.pinnedEntryIds);
    if (!pinned.add(normalized)) {
      pinned.remove(normalized);
    }
    mobileHomeLayout = mobileHomeLayout.copyWith(pinnedEntryIds: pinned);
    _notifyStateChanged();
    await mobileHomeLayoutService.save(portableData, mobileHomeLayout);
  }
}
