import 'package:licoup/src/application/state/application_signal.dart';
import 'package:licoup/src/contracts/agent_conversation_attachment.dart';
import 'package:licoup/src/contracts/presentation/composer_drafts.dart';

/// Renderer-facing conversation signals kept separate from conversation data
/// and transport state.
final class ConversationPresentationSignals {
  final ApplicationSignalOwner _structure = ApplicationSignalOwner();
  final ApplicationSignalOwner _active = ApplicationSignalOwner();
  final ApplicationSignalOwner _live = ApplicationSignalOwner();
  final ApplicationSignalOwner _tabActivity = ApplicationSignalOwner();
  Map<String, String> _composerDrafts = const {};
  Map<String, List<ConversationAttachment>> _composerAttachments = const {};
  Map<String, String> _composerAttachmentStatuses = const {};
  bool _disposed = false;

  /// Durable owner of the drafts above, bound by [loadComposerDrafts]. Until a
  /// document is admitted, drafts stay in memory and the existing bytes on
  /// disk are never replaced by an empty document.
  ComposerDraftStore? _draftStore;
  Object? _draftPortableData;
  bool _draftsLoading = false;
  bool _draftsBound = false;
  final Set<String> _draftScopesEditedDuringLoad = <String>{};
  Map<String, String>? _queuedDraftSnapshot;
  Future<void> _draftWriteTail = Future<void>.value();
  bool _draftWriteActive = false;

  Stream<ApplicationChange> get structureChanges => _structure.signal.changes;
  Stream<ApplicationChange> get activeChanges => _active.signal.changes;
  Stream<ApplicationChange> get liveChanges => _live.signal.changes;
  Stream<ApplicationChange> get tabActivityChanges =>
      _tabActivity.signal.changes;

  /// Draft text for one conversation scope. Every selected conversation (and
  /// every new-conversation draft) keeps its own composer text; switching
  /// conversations never leaks or overwrites another conversation's draft.
  String composerDraftFor(String scopeKey) {
    final normalized = scopeKey.trim();
    return normalized.isEmpty ? '' : (_composerDrafts[normalized] ?? '');
  }

  void replaceComposerDraft(String scopeKey, String value) {
    if (_disposed) return;
    final normalized = scopeKey.trim();
    if (normalized.isEmpty) return;
    final next = value;
    final previous = _composerDrafts[normalized] ?? '';
    if (next == previous) return;
    _composerDrafts = {..._composerDrafts, normalized: next};
    // Deliberately no _active.publish(): drafts mutate at keystroke rate and
    // an active publish recomputes and equality-scans every conversation
    // projection. The intent layer publishes only the composer channel after
    // this mutation; send/clear paths follow with their own full publishes.
    if (_draftsLoading) {
      // Reading is still in flight, so the stored document is not merged yet.
      // Remembering the scope keeps the user's typing rather than letting the
      // restore replace it, and the first write follows the merge.
      _draftScopesEditedDuringLoad.add(normalized);
      return;
    }
    _scheduleComposerDraftSave();
  }

  /// Binds and reads the durable draft document, then merges it under the live
  /// drafts. Text typed while the read was in flight wins for its own scope.
  ///
  /// Returns whether the document was admitted. An unreadable document answers
  /// `false`: drafts stay in memory and the preserved bytes are not rewritten.
  Future<bool> loadComposerDrafts({
    required ComposerDraftStore store,
    required Object portableData,
  }) async {
    if (_disposed) return false;
    _draftsBound = false;
    _draftStore = null;
    _draftPortableData = null;
    _draftsLoading = true;
    Map<String, String>? restored;
    try {
      restored = await store.load(portableData);
    } on Object {
      restored = null;
    }
    _draftsLoading = false;
    if (_disposed) return false;
    if (restored == null) return false;
    _draftStore = store;
    _draftPortableData = portableData;
    _draftsBound = true;
    var installed = false;
    for (final entry in restored.entries) {
      if (_draftScopesEditedDuringLoad.contains(entry.key)) continue;
      if ((_composerDrafts[entry.key] ?? '') == entry.value) continue;
      _composerDrafts = {..._composerDrafts, entry.key: entry.value};
      installed = true;
    }
    final editedDuringLoad = _draftScopesEditedDuringLoad.isNotEmpty;
    _draftScopesEditedDuringLoad.clear();
    // A scope typed into during the read is not in the document yet, so the
    // merged result is written once here.
    if (editedDuringLoad) _scheduleComposerDraftSave();
    if (installed) {
      // The composer projection was computed before this restore; it must see
      // the restored text once. Only the composer content changed, so the
      // active channel stays quiet.
      notifyStructureChanged(activeChanged: false);
    }
    return true;
  }

  /// Completes once every scheduled draft write has settled.
  Future<void> flushComposerDrafts() => _draftWriteTail;

  void _scheduleComposerDraftSave() {
    if (_disposed || !_draftsBound) return;
    _queuedDraftSnapshot = Map<String, String>.unmodifiable(_composerDrafts);
    if (_draftWriteActive) return;
    _draftWriteActive = true;
    _draftWriteTail = _drainComposerDraftSaves();
  }

  /// Writes the newest snapshot, coalescing edits that arrive during a write so
  /// a keystroke burst never queues one document write per keystroke.
  Future<void> _drainComposerDraftSaves() async {
    try {
      while (true) {
        final snapshot = _queuedDraftSnapshot;
        final store = _draftStore;
        final portableData = _draftPortableData;
        if (snapshot == null || store == null || portableData == null) break;
        _queuedDraftSnapshot = null;
        try {
          await store.save(portableData, snapshot);
        } on Object {
          // A failed draft write never blocks typing; the next edit retries.
        }
      }
    } finally {
      _draftWriteActive = false;
    }
  }

  /// Pending image attachments for one conversation scope, beside the text
  /// draft. The list is bounded and immutable; it is cleared only after
  /// terminal native success and never placed in widget state.
  List<ConversationAttachment> composerAttachmentsFor(String scopeKey) {
    final normalized = scopeKey.trim();
    if (normalized.isEmpty) return const [];
    return _composerAttachments[normalized] ?? const [];
  }

  /// Stable redacted picker outcome code for one scope (empty when the last
  /// picker interaction succeeded or none happened).
  String composerAttachmentStatusFor(String scopeKey) {
    final normalized = scopeKey.trim();
    if (normalized.isEmpty) return '';
    return _composerAttachmentStatuses[normalized] ?? '';
  }

  void replaceComposerAttachments(
    String scopeKey,
    List<ConversationAttachment> value,
  ) {
    if (_disposed) return;
    final normalized = scopeKey.trim();
    if (normalized.isEmpty) return;
    final next = List<ConversationAttachment>.unmodifiable(value);
    final previous = _composerAttachments[normalized] ?? const [];
    if (_sameAttachmentList(previous, next)) return;
    _composerAttachments = {..._composerAttachments, normalized: next};
    _active.publish();
  }

  void replaceComposerAttachmentStatus(String scopeKey, String code) {
    if (_disposed) return;
    final normalized = scopeKey.trim();
    if (normalized.isEmpty) return;
    final next = code.trim();
    final previous = _composerAttachmentStatuses[normalized] ?? '';
    if (next == previous) return;
    _composerAttachmentStatuses = {
      ..._composerAttachmentStatuses,
      normalized: next,
    };
    _active.publish();
  }

  bool _sameAttachmentList(
    List<ConversationAttachment> left,
    List<ConversationAttachment> right,
  ) {
    if (identical(left, right)) return true;
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      final a = left[index];
      final b = right[index];
      if (a.id != b.id ||
          a.name != b.name ||
          a.mediaType != b.mediaType ||
          a.path != b.path) {
        return false;
      }
    }
    return true;
  }

  void notifyStructureChanged({bool activeChanged = true}) {
    if (_disposed) return;
    _structure.publish();
    if (activeChanged) _active.publish();
  }

  void notifyActiveChanged() {
    if (_disposed) return;
    _active.publish();
  }

  void notifyLiveChanged() {
    if (_disposed) return;
    _live.publish();
  }

  void notifyTabActivityChanged() {
    if (_disposed) return;
    _tabActivity.publish();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _structure.close();
    _active.close();
    _live.close();
    _tabActivity.close();
  }
}
