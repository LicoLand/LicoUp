import 'package:licoup/src/application/state/application_signal.dart';
import 'package:licoup/src/contracts/agent_conversation_attachment.dart';

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
