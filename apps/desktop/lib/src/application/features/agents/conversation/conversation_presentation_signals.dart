import 'package:flutter/foundation.dart';

/// Renderer-facing conversation signals kept separate from conversation data
/// and transport state.
final class ConversationPresentationSignals {
  final ValueNotifier<int> _structureRevision = ValueNotifier<int>(0);
  final ValueNotifier<int> _activeRevision = ValueNotifier<int>(0);
  final ValueNotifier<int> _liveRevision = ValueNotifier<int>(0);
  Map<String, String> _composerDrafts = const {};
  bool _disposed = false;

  ValueListenable<int> get structureListenable => _structureRevision;
  ValueListenable<int> get activeListenable => _activeRevision;
  ValueListenable<int> get liveListenable => _liveRevision;

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
    _composerDrafts = {
      ..._composerDrafts,
      normalized: next,
    };
  }

  void notifyStructureChanged({bool activeChanged = true}) {
    if (_disposed) return;
    _structureRevision.value += 1;
    if (activeChanged) _activeRevision.value += 1;
  }

  void notifyActiveChanged() {
    if (_disposed) return;
    _activeRevision.value += 1;
  }

  void notifyLiveChanged() {
    if (_disposed) return;
    _liveRevision.value += 1;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _structureRevision.dispose();
    _activeRevision.dispose();
    _liveRevision.dispose();
  }
}
