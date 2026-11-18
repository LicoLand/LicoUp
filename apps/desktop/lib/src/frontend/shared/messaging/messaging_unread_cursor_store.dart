/// One loaded cursor document: the conversation read cursors plus the
/// coverage baseline — the instant the durable document started accounting
/// for conversations. A conversation whose last activity predates the
/// baseline is pre-existing history the badge adopts (marks read) lazily on
/// first sight; one with activity after it is genuinely new and badges its
/// full count until opened.
final class MessagingUnreadCursorSnapshot {
  const MessagingUnreadCursorSnapshot({
    required this.cursors,
    required this.baselineAtUnixMs,
  });

  /// `conversationId` → last-seen event count.
  final Map<String, int> cursors;

  /// Unix-millisecond instant covered by the durable document.
  final int baselineAtUnixMs;
}

/// Renderer-facing port for the durable conversation read cursors
/// (`messaging-unread-cursors.json`).
///
/// The sidebar depends on this port; the platform layer ships the file-backed
/// implementation without naming it here, and the composition root adapts one
/// onto the other (`PlatformMessagingUnreadCursorStoreAdapter`). The
/// `portableData` argument stays an opaque [Object] so the port never names
/// the platform data-root type.
///
/// A cursor records the event count the local user last saw in one
/// conversation; the unread badge is the delta between the conversation's
/// current count and its cursor.
abstract class MessagingUnreadCursorStore {
  const MessagingUnreadCursorStore();

  /// The last cursor map resolved by the installed store in this process.
  ///
  /// The composition adapter updates this on every completed load or save so
  /// a remounting sidebar can start from the known cursors synchronously
  /// instead of flashing every row as read. Test doubles never touch it,
  /// keeping widget tests isolated from each other.
  static Map<String, int>? lastKnownCursors;

  /// The stored snapshot, or null when no document exists yet — the caller
  /// seeds every currently known conversation at its current count so a
  /// first-run upgrade never floods the list with stale unread badges.
  Future<MessagingUnreadCursorSnapshot?> load(Object portableData);

  /// Persists [cursors] (`conversationId` → last-seen event count) with an
  /// atomic replace. The implementation keeps the document's existing
  /// coverage baseline so a rewrite cannot silently adopt conversations
  /// that were genuinely new.
  Future<void> save(Object portableData, Map<String, int> cursors);
}
