import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:licoup/src/contracts/presentation/desktop_dock_layout.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/desktop_app_catalog.dart';
import 'package:licoup/src/frontend/shared/client_platform_ports.dart';
import 'package:licoup/src/frontend/shared/desktop_dock_layout_store.dart';

/// One entry of the arrangeable built-in group: an app icon, or an iOS-style
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

/// Stored name prefix of a pinned plugin window.
const String _pluginPrefix = 'plugin:';

/// Owns the Desktop dock arrangement: the order and folders of the built-in
/// group, the pinned plugin windows, and persistence through
/// `desktop-dock-layout.json`.
///
/// The arrangement is independent of which apps are running: every app in
/// [desktopDockApps] is always present exactly once. Loading keeps the stored
/// order and inserts any missing app after the nearest app that precedes it
/// in catalog order. Every mutation applies in memory, notifies, then
/// persists fire-and-forget; the store's serialized atomic writes keep the
/// file consistent.
final class DesktopDockModel extends ChangeNotifier {
  DesktopDockModel({DesktopDockLayoutStore? store, Object? portableData})
    : _store = store ?? ClientPlatformPorts.dockLayoutStore(),
      _portableData =
          portableData ?? ClientPlatformPorts.portableData ?? const Object();

  final DesktopDockLayoutStore _store;
  final Object _portableData;

  List<DesktopDockEntry> _entries = normalizeDesktopDockEntries(const []);
  List<String> _pinnedPlugins = const [];
  bool _ready = false;
  int _folderSequence = 0;

  /// The built-in group in display order.
  List<DesktopDockEntry> get entries => _entries;

  /// Pinned plugin windows in display order.
  List<String> get pinnedPlugins => _pinnedPlugins;

  /// True once the stored arrangement is applied. Until then [entries] is the
  /// catalog default, and shells keep the dock hidden so a restored order
  /// never visibly replaces the default.
  bool get ready => _ready;

  bool isPluginPinned(String pluginId) => _pinnedPlugins.contains(pluginId);

  Future<void> load() async {
    final snapshot = await _store.load(_portableData);
    final entries = <DesktopDockEntry>[];
    final plugins = <String>[];
    for (final stored in snapshot.entries) {
      switch (stored) {
        case DesktopDockStoredAppEntry(app: final name):
          if (name.startsWith(_pluginPrefix)) {
            final id = name.substring(_pluginPrefix.length);
            if (id.isNotEmpty && !plugins.contains(id)) plugins.add(id);
            continue;
          }
          final app = desktopAppByName(name);
          if (app != null) entries.add(DesktopDockAppEntry(app));
        case DesktopDockStoredFolderEntry(id: final id, children: final raw):
          final children = <DesktopAppId>[
            for (final name in raw) ?desktopAppByName(name),
          ];
          entries.add(DesktopDockFolderEntry(id: id, children: children));
      }
    }
    _apply(normalizeDesktopDockEntries(entries), plugins);
  }

  /// Test seam: widget tests cannot await real file I/O inside the fake
  /// zone, so they seed an arrangement synchronously and mark the model
  /// ready. Persists nothing.
  void debugSeed(
    List<DesktopDockEntry> entries, {
    List<String> pinnedPlugins = const [],
  }) {
    _apply(normalizeDesktopDockEntries(entries), pinnedPlugins);
  }

  void _apply(List<DesktopDockEntry> entries, List<String> plugins) {
    _entries = entries;
    _pinnedPlugins = List.unmodifiable(plugins);
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

  /// Moves the entry with [storageId] so it lands at gap [targetIndex] — the
  /// insertion point before the entry currently sitting at that index
  /// (indices match the dock's gap drop zones). Out-of-range indices clamp.
  bool moveEntry(String storageId, int targetIndex) {
    final from = _entries.indexWhere((entry) => entry.storageId == storageId);
    if (from < 0) return false;
    final clamped = targetIndex.clamp(0, _entries.length);
    final adjusted = clamped > from ? clamped - 1 : clamped;
    if (adjusted == from) return false;
    final next = [..._entries];
    final entry = next.removeAt(from);
    next.insert(adjusted, entry);
    return _mutate(entries: next);
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
    final next = [..._entries]..removeAt(draggedIndex);
    final slot = next.indexWhere((entry) => entry.storageId == targetStorageId);
    switch (target) {
      case DesktopDockAppEntry(app: final targetApp):
        _folderSequence += 1;
        next[slot] = DesktopDockFolderEntry(
          id: 'folder-$_folderSequence',
          children: List.unmodifiable([targetApp, dragged.app]),
        );
      case DesktopDockFolderEntry(id: final id, children: final children):
        next[slot] = DesktopDockFolderEntry(
          id: id,
          children: List.unmodifiable([...children, dragged.app]),
        );
    }
    return _mutate(entries: next);
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
      (entry) => entry is DesktopDockFolderEntry && entry.id == folderId,
    );
    if (folderIndex < 0) return false;
    final folder = _entries[folderIndex] as DesktopDockFolderEntry;
    if (!folder.children.contains(app)) return false;
    final next = [..._entries];
    final remaining = folder.children
        .where((child) => child != app)
        .toList(growable: false);
    next.removeAt(folderIndex);
    if (remaining.length >= 2) {
      next.insert(
        folderIndex,
        DesktopDockFolderEntry(
          id: folder.id,
          children: List.unmodifiable(remaining),
        ),
      );
    } else if (remaining.length == 1) {
      next.insert(folderIndex, DesktopDockAppEntry(remaining.single));
    }
    final index = insertIndex == null
        ? next.length
        : insertIndex.clamp(0, next.length);
    next.insert(index, DesktopDockAppEntry(app));
    return _mutate(entries: next);
  }

  /// Keeps the plugin window in the dock while it is closed.
  bool pinPlugin(String pluginId) {
    if (pluginId.isEmpty || isPluginPinned(pluginId)) return false;
    return _mutate(plugins: [..._pinnedPlugins, pluginId]);
  }

  bool unpinPlugin(String pluginId) {
    if (!isPluginPinned(pluginId)) return false;
    return _mutate(
      plugins: [
        for (final id in _pinnedPlugins)
          if (id != pluginId) id,
      ],
    );
  }

  bool _mutate({List<DesktopDockEntry>? entries, List<String>? plugins}) {
    if (entries != null) _entries = List.unmodifiable(entries);
    if (plugins != null) _pinnedPlugins = List.unmodifiable(plugins);
    notifyListeners();
    unawaited(_persist());
    return true;
  }

  Future<void> _persist() async {
    final stored = <DesktopDockStoredEntry>[
      for (final entry in _entries)
        switch (entry) {
          DesktopDockAppEntry(app: final app) => DesktopDockStoredAppEntry(
            app.name,
          ),
          DesktopDockFolderEntry(id: final id, children: final children) =>
            DesktopDockStoredFolderEntry(
              id: id,
              children: [for (final app in children) app.name],
            ),
        },
      for (final id in _pinnedPlugins)
        DesktopDockStoredAppEntry('$_pluginPrefix$id'),
    ];
    await _store.save(
      _portableData,
      DesktopDockLayoutSnapshot(entries: stored),
    );
  }
}

/// The built-in group as stored order plus completeness: apps outside
/// [desktopDockApps] and repeated apps are dropped, folders left with one
/// child dissolve and empty ones disappear, and every missing app is
/// inserted right after the nearest app that precedes it in catalog order
/// (at the front when none does).
List<DesktopDockEntry> normalizeDesktopDockEntries(
  List<DesktopDockEntry> stored,
) {
  final seen = <DesktopAppId>{};
  bool admit(DesktopAppId app) =>
      desktopDockApps.contains(app) && seen.add(app);
  final entries = <DesktopDockEntry>[];
  final folderIds = <String>{};
  for (final entry in stored) {
    switch (entry) {
      case DesktopDockAppEntry(app: final app):
        if (admit(app)) entries.add(entry);
      case DesktopDockFolderEntry(id: final id, children: final children):
        final kept = [
          for (final app in children)
            if (admit(app)) app,
        ];
        if (kept.length >= 2 && folderIds.add(id)) {
          entries.add(
            DesktopDockFolderEntry(id: id, children: List.unmodifiable(kept)),
          );
        } else {
          entries.addAll([for (final app in kept) DesktopDockAppEntry(app)]);
        }
    }
  }
  int entryIndexOf(DesktopAppId app) => entries.indexWhere(
    (entry) => switch (entry) {
      DesktopDockAppEntry(app: final value) => value == app,
      DesktopDockFolderEntry(children: final children) => children.contains(
        app,
      ),
    },
  );
  for (var catalog = 0; catalog < desktopDockApps.length; catalog++) {
    final app = desktopDockApps[catalog];
    if (seen.contains(app)) continue;
    var insertAt = 0;
    for (var previous = catalog - 1; previous >= 0; previous--) {
      final index = entryIndexOf(desktopDockApps[previous]);
      if (index >= 0) {
        insertAt = index + 1;
        break;
      }
    }
    entries.insert(insertAt, DesktopDockAppEntry(app));
    seen.add(app);
  }
  return List.unmodifiable(entries);
}
