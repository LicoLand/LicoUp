import 'package:licoup/src/platform/mobile_relay/mobile_relay_json_store.dart';

/// One stored dock entry in `desktop-dock-layout.json`: either an app icon or
/// an iOS-style folder holding an ordered child list. Nesting is disallowed,
/// so the tree stays one level deep.
sealed class DesktopDockStoredEntry {
  const DesktopDockStoredEntry();
}

final class DesktopDockStoredAppEntry extends DesktopDockStoredEntry {
  const DesktopDockStoredAppEntry(this.app);

  final String app;
}

final class DesktopDockStoredFolderEntry extends DesktopDockStoredEntry {
  const DesktopDockStoredFolderEntry({required this.id, required this.children});

  final String id;
  final List<String> children;
}

/// The persisted dock layout: the ordered entry list after the pinned icons.
final class DesktopDockLayoutSnapshot {
  const DesktopDockLayoutSnapshot({required this.entries});

  final List<DesktopDockStoredEntry> entries;
}

/// File-backed store for the Desktop dock layout. Dock order is pure
/// presentation state, so load is fully tolerant: a missing, malformed, or
/// foreign-version document falls back to the default empty dock instead of
/// failing startup. Writes follow the shared atomic temp-file replace idiom.
final class DesktopDockLayoutStore {
  const DesktopDockLayoutStore({
    MobileRelayJsonStore jsonStore = const MobileRelayJsonStore(),
  }) : _jsonStore = jsonStore;

  static const fileName = 'desktop-dock-layout.json';
  static const _schemaVersion = 1;
  static const _maxEntries = 64;
  static const _maxFolderChildren = 32;
  static const _maxIdLength = 128;

  final MobileRelayJsonStore _jsonStore;

  Future<DesktopDockLayoutSnapshot> load(Object portableData) async {
    final decoded = await _jsonStore.read(portableData, fileName);
    if (decoded is! Map || decoded['schemaVersion'] != _schemaVersion) {
      return const DesktopDockLayoutSnapshot(entries: []);
    }
    final rawEntries = decoded['entries'];
    if (rawEntries is! List) {
      return const DesktopDockLayoutSnapshot(entries: []);
    }
    final entries = <DesktopDockStoredEntry>[];
    final seenApps = <String>{};
    for (final raw in rawEntries) {
      if (entries.length >= _maxEntries) break;
      if (raw is! Map) continue;
      if (raw['type'] == 'app') {
        final app = _normalizeId(raw['app']);
        if (app.isEmpty || !seenApps.add(app)) continue;
        entries.add(DesktopDockStoredAppEntry(app));
        continue;
      }
      if (raw['type'] == 'folder') {
        final id = _normalizeId(raw['id']);
        final rawChildren = raw['children'];
        if (id.isEmpty || rawChildren is! List) continue;
        final children = <String>[];
        for (final rawChild in rawChildren) {
          if (children.length >= _maxFolderChildren) break;
          final child = _normalizeId(rawChild);
          if (child.isEmpty || !seenApps.add(child)) continue;
          children.add(child);
        }
        if (children.isEmpty) continue;
        if (children.length == 1) {
          entries.add(DesktopDockStoredAppEntry(children.single));
          continue;
        }
        entries.add(DesktopDockStoredFolderEntry(id: id, children: children));
      }
    }
    return DesktopDockLayoutSnapshot(entries: List.unmodifiable(entries));
  }

  Future<void> save(
    Object portableData,
    DesktopDockLayoutSnapshot snapshot,
  ) async {
    final entries = <Map<String, Object?>>[];
    final seenApps = <String>{};
    for (final entry in snapshot.entries) {
      if (entries.length >= _maxEntries) break;
      switch (entry) {
        case DesktopDockStoredAppEntry(app: final app):
          final id = _normalizeId(app);
          if (id.isEmpty || !seenApps.add(id)) continue;
          entries.add(<String, Object?>{'type': 'app', 'app': id});
        case DesktopDockStoredFolderEntry(id: final id, children: final raw):
          final folderId = _normalizeId(id);
          if (folderId.isEmpty) continue;
          final children = <String>[];
          for (final child in raw) {
            if (children.length >= _maxFolderChildren) break;
            final normalized = _normalizeId(child);
            if (normalized.isEmpty || !seenApps.add(normalized)) continue;
            children.add(normalized);
          }
          if (children.length < 2) {
            if (children.length == 1) {
              entries.add(<String, Object?>{
                'type': 'app',
                'app': children.single,
              });
            }
            continue;
          }
          entries.add(<String, Object?>{
            'type': 'folder',
            'id': folderId,
            'children': children,
          });
      }
    }
    await _jsonStore.write(portableData, fileName, {
      'schemaVersion': _schemaVersion,
      'entries': entries,
    }, lock: true);
  }

  String _normalizeId(Object? value) {
    final id = value?.toString().trim() ?? '';
    return id.length <= _maxIdLength ? id : '';
  }
}
