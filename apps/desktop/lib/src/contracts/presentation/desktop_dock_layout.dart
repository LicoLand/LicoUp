/// Stored model of the Desktop dock layout (`desktop-dock-layout.json`) —
/// the semantic value shared by the renderer-facing store port and its
/// platform-backed implementation.
///
/// The stored model is pure presentation state: an ordered entry list where
/// each entry is an app icon or an iOS-style folder holding an ordered child
/// list. Nesting is disallowed, so the tree stays one level deep.
sealed class DesktopDockStoredEntry {
  const DesktopDockStoredEntry();
}

final class DesktopDockStoredAppEntry extends DesktopDockStoredEntry {
  const DesktopDockStoredAppEntry(this.app);

  final String app;
}

final class DesktopDockStoredFolderEntry extends DesktopDockStoredEntry {
  const DesktopDockStoredFolderEntry({
    required this.id,
    required this.children,
  });

  final String id;
  final List<String> children;
}

/// The persisted dock layout: the ordered entry list after the pinned icons.
final class DesktopDockLayoutSnapshot {
  const DesktopDockLayoutSnapshot({required this.entries});

  final List<DesktopDockStoredEntry> entries;
}
