import 'package:licoup/src/contracts/collaboration_run_port.dart';
import 'package:licoup/src/presentation/collaboration/collaboration_binding.dart';
import 'package:licoup/src/projections/collaboration/collaboration_presentation_source.dart';

/// Conversation-scoped collaboration feature wiring over the reserved run
/// port.
///
/// The native producer does not exist yet, so the root registers
/// [UnavailableCollaborationRunPort]. Each conversation owns at most one
/// source: [bindingFor] returns the existing binding while it is retained,
/// [release] disposes it, and [close] disposes every retained source.
final class CollaborationFeatureComposition {
  CollaborationFeatureComposition({
    CollaborationRunPort? port,
    CollaborationBinding Function(CollaborationPresentationSource source)?
    wrapBinding,
  }) : _port = port ?? const UnavailableCollaborationRunPort(),
       _wrapBinding =
           wrapBinding ??
           ((source) => CollaborationBinding(
             projection: source,
             intents: source,
             effects: source,
           ));

  final CollaborationRunPort _port;
  final CollaborationBinding Function(CollaborationPresentationSource source)
  _wrapBinding;
  final Map<String, _ConversationCollaboration> _conversations = {};
  bool _closed = false;

  /// The registered run port; replaceable in tests by passing `port`.
  CollaborationRunPort get port => _port;

  /// The binding observing [conversationId], created on first request.
  CollaborationBinding bindingFor(String conversationId) {
    if (_closed) {
      throw StateError('collaboration_composition_closed');
    }
    return _conversations.putIfAbsent(conversationId, () {
      final source = CollaborationPresentationSource(
        port: _port,
        conversationId: conversationId,
      );
      return _ConversationCollaboration(source, _wrapBinding(source));
    }).binding;
  }

  /// Disposes the source of [conversationId]; a later [bindingFor] starts a
  /// fresh observation.
  Future<void> release(String conversationId) async {
    final entry = _conversations.remove(conversationId);
    await entry?.source.dispose();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final entries = _conversations.values.toList();
    _conversations.clear();
    for (final entry in entries) {
      await entry.source.dispose();
    }
  }
}

final class _ConversationCollaboration {
  const _ConversationCollaboration(this.source, this.binding);

  final CollaborationPresentationSource source;
  final CollaborationBinding binding;
}
