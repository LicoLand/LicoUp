import 'package:licoup/src/contracts/collaboration_run_models.dart';

/// Reserved port for the native collaboration-run producer.
///
/// One projection per Conversation run, pushed on every committed change.
/// Commands carry the observed head number; a stale head returns
/// [CollaborationCommandResultConflict].
abstract interface class CollaborationRunPort {
  /// Pushed projection for [conversationId], or null while the conversation
  /// has no collaboration run. A stream error means the port cannot serve
  /// the conversation.
  Stream<CollaborationRunSnapshot?> watchConversation(String conversationId);

  /// Loads the complete graph of revision [number] on demand. Historical
  /// graphs are requested only when the user selects that revision.
  Future<CollaborationGraph> loadRevision(String runId, int number);

  Future<CollaborationCommandResult> send(
    String runId,
    CollaborationCommand command,
  );
}

/// Placeholder used until the native producer lands. Observation fails and
/// commands are rejected, both with [collaborationRunUnavailable].
final class UnavailableCollaborationRunPort implements CollaborationRunPort {
  const UnavailableCollaborationRunPort();

  @override
  Stream<CollaborationRunSnapshot?> watchConversation(String conversationId) =>
      Stream<CollaborationRunSnapshot?>.error(
        StateError(collaborationRunUnavailable),
      );

  @override
  Future<CollaborationGraph> loadRevision(String runId, int number) =>
      Future<CollaborationGraph>.error(StateError(collaborationRunUnavailable));

  @override
  Future<CollaborationCommandResult> send(
    String runId,
    CollaborationCommand command,
  ) => Future<CollaborationCommandResult>.value(
    const CollaborationCommandResultRejected(collaborationRunUnavailable),
  );
}
