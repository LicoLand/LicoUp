import 'package:flutter/foundation.dart';

/// Renderer-facing conversation signals kept separate from conversation data
/// and transport state.
final class ConversationPresentationSignals {
  final ValueNotifier<int> _structureRevision = ValueNotifier<int>(0);
  final ValueNotifier<int> _activeRevision = ValueNotifier<int>(0);
  final ValueNotifier<int> _liveRevision = ValueNotifier<int>(0);
  String _composerDraft = '';
  bool _disposed = false;

  ValueListenable<int> get structureListenable => _structureRevision;
  ValueListenable<int> get activeListenable => _activeRevision;
  ValueListenable<int> get liveListenable => _liveRevision;
  String get composerDraft => _composerDraft;

  void replaceComposerDraft(String value) {
    if (_disposed) return;
    _composerDraft = value;
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
