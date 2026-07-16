import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'package:flutter_client/src/contracts/mobile_home_layout.dart';
import 'package:flutter_client/src/contracts/mobile_home_layout_repository.dart';

/// Owns Mobile Home ordering, pinning, and serialized persistence.
final class MobileHomeLayoutController extends ChangeNotifier {
  MobileHomeLayoutController({required MobileHomeLayoutRepository repository})
    : _repository = repository;

  final MobileHomeLayoutRepository _repository;
  MobileHomeLayout _layout = MobileHomeLayout.defaults();
  Future<void> _persistTail = Future<void>.value();

  MobileHomeLayout get layout => _layout;

  Future<void> load() async {
    _layout = _sanitized(await _repository.load());
    notifyListeners();
  }

  void replaceLayout(MobileHomeLayout value) {
    _layout = _sanitized(value);
    notifyListeners();
  }

  MobileHomeLayout _sanitized(MobileHomeLayout value) {
    return MobileHomeLayout(
      order: value.order
          .where(MobileHomeLayout.isSupportedEntryId)
          .toList(growable: false),
      pinnedEntryIds: value.pinnedEntryIds
          .where(MobileHomeLayout.isSupportedEntryId)
          .toSet(),
    );
  }

  Future<void> reorderPinnedEntries(
    List<String> pinnedEntryIds,
    int oldIndex,
    int newIndex,
  ) async {
    final pinned = LinkedHashSet<String>.from(
      pinnedEntryIds
          .map((id) => id.trim())
          .where(MobileHomeLayout.isSupportedEntryId),
    ).toList(growable: true);
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
    pinned.insert(insertIndex.clamp(0, pinned.length), moved);
    final pinnedSet = pinned.toSet();
    _layout = _layout.copyWith(
      order: [
        ...pinned,
        for (final id in _layout.order)
          if (!pinnedSet.contains(id)) id,
      ],
    );
    notifyListeners();
    await _persist(_layout);
  }

  Future<void> togglePinned(String entryId) async {
    final normalized = entryId.trim();
    if (!MobileHomeLayout.isSupportedEntryId(normalized)) {
      return;
    }
    final pinned = Set<String>.from(_layout.pinnedEntryIds);
    if (!pinned.add(normalized)) {
      pinned.remove(normalized);
    }
    _layout = _layout.copyWith(pinnedEntryIds: pinned);
    notifyListeners();
    await _persist(_layout);
  }

  Future<void> removeEntries(Set<String> entryIds) async {
    final removed = entryIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    if (removed.isEmpty ||
        (!_layout.order.any(removed.contains) &&
            !_layout.pinnedEntryIds.any(removed.contains))) {
      return;
    }
    _layout = _layout.copyWith(
      order: [
        for (final id in _layout.order)
          if (!removed.contains(id)) id,
      ],
      pinnedEntryIds: {
        for (final id in _layout.pinnedEntryIds)
          if (!removed.contains(id)) id,
      },
    );
    notifyListeners();
    await _persist(_layout);
  }

  Future<void> _persist(MobileHomeLayout snapshot) {
    final operation = _persistTail.then((_) => _repository.save(snapshot));
    _persistTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }
}
