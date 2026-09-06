import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:licoup/src/contracts/presentation/desktop_dock_layout.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/desktop_app_catalog.dart';
import 'package:licoup/src/frontend/shared/client_platform_ports.dart';
import 'package:licoup/src/frontend/shared/desktop_dock_layout_store.dart';

/// One dock entry after the pinned icons: an app icon, or an iOS-style
/// folder with an ordered child list. Nesting is disallowed; the sealed type
/// is the whole model.
sealed class DesktopDockEntry {
  const DesktopDockEntry();

  String get storageId;
}

final class DesktopDockAppEntry extends DesktopDockEntry {
  const DesktopDockAppEntry(this.app);

  final DesktopAppId app;

  @override
  String get storageId => 'app:${app.name}';
}

final class DesktopDockFolderEntry extends DesktopDockEntry {
  const DesktopDockFolderEntry({required this.id, required this.children});

  final String id;
  final List<DesktopAppId> children;

  @override
  String get storageId => 'folder:$id';
}

/// Owns the Desktop dock layout: entries (order + folders), the open-app set
/// derived from them, and persistence through `desktop-dock-layout.json`.
/// Every mutation applies in memory, notifies, then persists fire-and-forget;
/// the store's serialized atomic writes keep the file consistent.
final class DesktopDockModel extends ChangeNotifier {
  DesktopDockModel({DesktopDockLayoutStore? store, Object? portableData})
    : _store = store ?? ClientPlatformPorts.dockLayoutStore(),
      _portableData =
          portableData ?? ClientPlatformPorts.portableData ?? const Object();

  final DesktopDockLayoutStore _store;
  final Object _portableData;

  List<DesktopDockEntry> _entries = const [];
  bool _ready = false;
  int _folderSequence = 0;

  List<DesktopDockEntry> get entries => List.unmodifiable(_entries);

  /// True once the initial load settled; shells render the default dock
  /// (pinned icons only) until then.
  bool get ready => _ready;

  /// Every app currently present in the dock, whether as an entry or inside
  /// a folder. This is the persisted open-app set.
  Set<DesktopAppId> get openApps {
    final apps = <DesktopAppId>{};
    for (final entry in _entries) {
      switch (entry) {
        case DesktopDockAppEntry(app: final app):
          apps.add(app);
        case DesktopDockFolderEntry(children: final children):
          apps.addAll(children);
      }
    }
    return apps;
  }

  bool isOpen(DesktopAppId app) => openApps.contains(app);

  Future<void> load() async {
    final snapshot = await _store.load(_portableData);
    final entries = <DesktopDockEntry>[];
    for (final stored in snapshot.entries) {
      switch (stored) {
        case DesktopDockStoredAppEntry(app: final appName):
          final app = desktopAppByName(appName);
          if (app == null) continue;
          entries.add(DesktopDockAppEntry(app));
        case DesktopDockStoredFolderEntry(id: final id, children: final raw):
          final children = <DesktopAppId>[];
          for (final childName in raw) {
            final app = desktopAppByName(childName);
            if (app == null) continue;
            children.add(app);
          }
          if (children.isEmpty) continue;
          if (children.length == 1) {
            entries.add(DesktopDockAppEntry(children.single));
            continue;
          }
          entries.add(DesktopDockFolderEntry(id: id, children: children));
      }
    }
    _applyLoaded(entries);
  }

  /// Test seam: widget tests cannot await real file I/O inside the fake
  /// zone, so they seed entries synchronously and mark the model ready.
  /// Persists nothing.
  void debugSeed(List<DesktopDockEntry> entries) {
    _applyLoaded(entries);
  }

  void _applyLoaded(List<DesktopDockEntry> entries) {
    _entries = List.unmodifiable(entries);
    var sequence = _entries.length;
    for (final entry in _entries) {
      if (entry is! DesktopDockFolderEntry) continue;
      final suffix = int.tryParse(entry.id.replaceFirst('folder-', ''));
      if (suffix != null && suffix > sequence) sequence = suffix;
    }
    _folderSequence = sequence;
    _ready = true;
    notifyListeners();
  }

  /// Adds the app to the dock unless it is already present (entry or folder
  /// child). Returns true when the dock changed.
  bool openApp(DesktopAppId app) {
    if (isOpen(app)) return false;
    return _mutate(
      () => _entries = List.unmodifiable([..._entries, DesktopDockAppEntry(app)]),
    );
  }

  /// Removes the app from the dock, dissolving its folder when it was the
  /// last-but-one child. Closing is a no-op for apps that are not open.
  bool closeApp(DesktopAppId app) {
    if (!isOpen(app)) return false;
    return _mutate(() {
      final next = <DesktopDockEntry>[];
      for (final entry in _entries) {
        switch (entry) {
          case DesktopDockAppEntry(app: final entryApp):
            if (entryApp != app) next.add(entry);
          case DesktopDockFolderEntry(id: final id, children: final children):
            final remaining = children
                .where((child) => child != app)
                .toList(growable: false);
            if (remaining.length == children.length) {
              next.add(entry);
            } else if (remaining.length >= 2) {
              next.add(DesktopDockFolderEntry(id: id, children: remaining));
            } else if (remaining.length == 1) {
              next.add(DesktopDockAppEntry(remaining.single));
            }
        }
      }
      _entries = List.unmodifiable(next);
    });
  }

  /// Moves the entry with [storageId] so it lands at gap [targetIndex] — the
  /// insertion point before the entry currently sitting at that index
  /// (indices match the dock's gap drop zones). Out-of-range indices clamp.
  bool moveEntry(String storageId, int targetIndex) {
    final from = _entries.indexWhere((entry) => entry.storageId == storageId);
    if (from < 0) return false;
    final clamped = targetIndex.clamp(0, _entries.length);
    final adjusted = clamped > from ? clamped - 1 : clamped;
    if (adjusted == from) return false;
    return _mutate(() {
      final next = [..._entries];
      final entry = next.removeAt(from);
      next.insert(adjusted, entry);
      _entries = List.unmodifiable(next);
    });
  }

  /// iOS-style folder creation: dropping [draggedStorageId] onto
  /// [targetStorageId]. Dropping an app onto an app creates a folder holding
  /// [target, dragged] at the target's slot; dropping an app onto a folder
  /// appends it; dropping a folder onto anything is rejected (no nesting).
  bool mergeEntries(String draggedStorageId, String targetStorageId) {
    if (draggedStorageId == targetStorageId) return false;
    final draggedIndex = _entries.indexWhere(
      (entry) => entry.storageId == draggedStorageId,
    );
    final targetIndex = _entries.indexWhere(
      (entry) => entry.storageId == targetStorageId,
    );
    if (draggedIndex < 0 || targetIndex < 0) return false;
    final dragged = _entries[draggedIndex];
    final target = _entries[targetIndex];
    if (dragged is! DesktopDockAppEntry) return false;
    final draggedApp = dragged.app;
    if (target is DesktopDockAppEntry && target.app == draggedApp) {
      return false;
    }
    return _mutate(() {
      final next = [..._entries];
      next.removeAt(draggedIndex);
      final adjustedTarget = next.indexWhere(
        (entry) => entry.storageId == targetStorageId,
      );
      switch (target) {
        case DesktopDockAppEntry(app: final targetApp):
          _folderSequence += 1;
          next[adjustedTarget] = DesktopDockFolderEntry(
            id: 'folder-$_folderSequence',
            children: [targetApp, draggedApp],
          );
        case DesktopDockFolderEntry(id: final id, children: final children):
          next[adjustedTarget] = DesktopDockFolderEntry(
            id: id,
            children: [...children, draggedApp],
          );
      }
      _entries = List.unmodifiable(next);
    });
  }

  /// Pulls one app out of its folder back into the entry list (at
  /// [insertIndex], appended when null). A folder left with a single child
  /// dissolves into that child's app entry.
  bool extractFromFolder(
    String folderId,
    DesktopAppId app, {
    int? insertIndex,
  }) {
    final folderIndex = _entries.indexWhere(
      (entry) =>
          entry is DesktopDockFolderEntry && entry.id == folderId,
    );
    if (folderIndex < 0) return false;
    final folder = _entries[folderIndex] as DesktopDockFolderEntry;
    if (!folder.children.contains(app)) return false;
    return _mutate(() {
      final next = [..._entries];
      final remaining = folder.children
          .where((child) => child != app)
          .toList(growable: false);
      next.removeAt(folderIndex);
      if (remaining.length >= 2) {
        next.insert(
          folderIndex,
          DesktopDockFolderEntry(id: folder.id, children: remaining),
        );
      } else if (remaining.length == 1) {
        next.insert(folderIndex, DesktopDockAppEntry(remaining.single));
      }
      final index = insertIndex == null
          ? next.length
          : insertIndex.clamp(0, next.length);
      next.insert(index, DesktopDockAppEntry(app));
      _entries = List.unmodifiable(next);
    });
  }

  bool _mutate(void Function() apply) {
    apply();
    notifyListeners();
    unawaited(_persist());
    return true;
  }

  Future<void> _persist() async {
    final stored = <DesktopDockStoredEntry>[];
    for (final entry in _entries) {
      switch (entry) {
        case DesktopDockAppEntry(app: final app):
          stored.add(DesktopDockStoredAppEntry(app.name));
        case DesktopDockFolderEntry(id: final id, children: final children):
          stored.add(
            DesktopDockStoredFolderEntry(
              id: id,
              children: [for (final app in children) app.name],
            ),
          );
      }
    }
    await _store.save(
      _portableData,
      DesktopDockLayoutSnapshot(entries: stored),
    );
  }
}
