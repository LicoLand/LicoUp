/// Durable composer drafts for one client data root.
///
/// A draft is unsent editing text the user already typed. It belongs to one
/// conversation scope and outlives the process that produced it, so a restart
/// returns the user to the text they had not sent. The store owns one document
/// under the client state directory; the presentation signal owner keeps the
/// live copy and asks this store to persist it.
///
/// The document is optional presentation state: an absent document is a fresh
/// domain, and an unreadable one must never be replaced by an empty document.
abstract interface class ComposerDraftStore {
  /// Reads the stored drafts keyed by conversation scope.
  ///
  /// Returns an empty map when no document exists yet. Returns `null` when a
  /// document exists but cannot be admitted; the caller then keeps drafts in
  /// memory only, so the unreadable bytes stay intact.
  Future<Map<String, String>?> load(Object portableData);

  /// Replaces the whole document with [drafts], dropping entries whose value is
  /// empty.
  Future<void> save(Object portableData, Map<String, String> drafts);
}
