import 'package:licoup/src/contracts/conversation_execution.dart';

/// Renderer-local identity for one open execution surface. It is never used
/// as an execution identity, persisted, or sent to the native runtime.
final class ConversationExecutionViewId {
  ConversationExecutionViewId();
}

/// Each entry mirrors the existing observation for that surface. The records
/// retain their immutable prefixes and original object identities.
final class ConversationExecutionProjection {
  ConversationExecutionProjection({
    Map<ConversationExecutionViewId, ConversationExecutionState> views =
        const {},
  }) : views = Map.unmodifiable(views);

  final Map<ConversationExecutionViewId, ConversationExecutionState> views;
}
