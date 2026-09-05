const double historySessionRowHeight = 72;
const double historySessionGroupedRowHeight = 36;
const double historySessionGroupHeaderHeight = 34;
const String historySessionLoadMoreStorageKey =
    'history-session-list-load-more';

class HistorySessionPanelItem {
  const HistorySessionPanelItem({
    required this.id,
    required this.title,
    this.meta = '',
    this.preview = '',
    this.groupKey = '',
    this.groupLabel = '',
    this.active = false,
    this.running = false,
    this.disabled = false,
    this.canDelete = true,
    this.deleteLabel,
  });

  final String id;
  final String title;
  final String meta;
  final String preview;

  /// Stable project/workspace key used for grouping (usually absolute cwd).
  final String groupKey;

  /// Display label for [groupKey] (usually the last path segment).
  final String groupLabel;
  final bool active;

  /// True while this session has an in-flight agent turn.
  final bool running;
  final bool disabled;
  final bool canDelete;
  final String? deleteLabel;
}

/// One render row in a project-grouped history list.
class HistorySessionListEntry {
  const HistorySessionListEntry.header({
    required this.groupKey,
    required this.groupLabel,
  }) : item = null,
       isHeader = true;

  const HistorySessionListEntry.item(this.item)
    : groupKey = '',
      groupLabel = '',
      isHeader = false;

  final bool isHeader;
  final String groupKey;
  final String groupLabel;
  final HistorySessionPanelItem? item;

  String get storageKey => isHeader
      ? historySessionGroupStorageKey(groupKey)
      : historySessionItemStorageKey(item!.id);
}

String historySessionItemStorageKey(String sessionId) => sessionId;

String historySessionGroupStorageKey(String groupKey) {
  return 'history-session-list-group-${groupKey.hashCode.toUnsigned(32).toRadixString(16)}';
}

/// Basename of a working directory for project-group headers.
String historySessionProjectLabel(
  String workingDirectory, {
  String fallback = 'No project',
}) {
  final trimmed = workingDirectory.trim();
  if (trimmed.isEmpty) return fallback;
  final normalized = trimmed
      .replaceAll('\\', '/')
      .replaceAll(RegExp(r'/+$'), '');
  final parts = normalized
      .split('/')
      .where((part) => part.isNotEmpty)
      .toList(growable: false);
  return parts.isEmpty ? fallback : parts.last;
}

final RegExp _sessionTitleControlTags = RegExp(
  r'^(<[/a-zA-Z][a-zA-Z0-9_-]*[^>]*>\s*)+',
);
final RegExp _sessionTitleHeadingMarker = RegExp(r'^#{1,6}\s+');
final RegExp _sessionTitleWhitespace = RegExp(r'\s+');
final RegExp _sessionTitleRolloutFile = RegExp(
  r'^rollout-\d{4}-\d{2}-\d{2}T\S*$',
);
final RegExp _sessionTitleUuid = RegExp(
  r'^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$',
);

/// Human-readable conversation title for list surfaces.
///
/// Catalog titles may arrive as rollout file names, agent control-tag
/// fragments (`<turn_aborted> …`), markdown headings, or bare session ids.
/// Those collapse to a readable fragment; unusable titles fall back to a
/// localized placeholder instead of leaking raw identifiers.
String historySessionDisplayTitle(String rawTitle, {required String fallback}) {
  var title = rawTitle.trim();
  for (var pass = 0; pass < 3; pass++) {
    final stripped = title
        .replaceFirst(_sessionTitleControlTags, '')
        .replaceFirst(_sessionTitleHeadingMarker, '')
        .trim();
    if (stripped == title) break;
    title = stripped;
  }
  title = title.replaceAll(_sessionTitleWhitespace, ' ').trim();
  if (title.isEmpty) return fallback;
  if (_sessionTitleRolloutFile.hasMatch(title)) return fallback;
  if (_sessionTitleUuid.hasMatch(title)) return fallback;
  return title;
}

/// Groups newest-first sessions while preserving first-seen project order.
List<HistorySessionListEntry> historySessionGroupEntries(
  List<HistorySessionPanelItem> items, {
  String ungroupedLabel = 'No project',
}) {
  final groups = <String, List<HistorySessionPanelItem>>{};
  final labels = <String, String>{};
  for (final item in items) {
    final key = item.groupKey.trim();
    (groups[key] ??= <HistorySessionPanelItem>[]).add(item);
    labels.putIfAbsent(
      key,
      () => item.groupLabel.trim().isEmpty
          ? ungroupedLabel
          : item.groupLabel.trim(),
    );
  }
  return [
    for (final entry in groups.entries) ...[
      HistorySessionListEntry.header(
        groupKey: entry.key,
        groupLabel: labels[entry.key] ?? ungroupedLabel,
      ),
      for (final item in entry.value) HistorySessionListEntry.item(item),
    ],
  ];
}
