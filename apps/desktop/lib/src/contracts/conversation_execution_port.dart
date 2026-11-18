import 'conversation_execution.dart';

/// Optional local capability; it is intentionally absent from remote gateways.
abstract interface class ConversationExecutionSource {
  Stream<ConversationExecutionEvent> watchExecution(
    ConversationExecutionReference reference, {
    int afterCursor = 0,
  });
}

abstract interface class ConversationExecutionReader {
  ConversationExecutionObservation observe(
    ConversationExecutionReference reference,
  );
}

abstract interface class ConversationExecutionObservation {
  ConversationExecutionState get snapshot;
  Stream<ConversationExecutionState> get changes;
  void reconnect();

  /// Detaches observation only. It cannot cancel the execution.
  void dispose();
}
