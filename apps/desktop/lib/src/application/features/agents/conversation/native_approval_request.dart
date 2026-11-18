/// One local native permission request an Agent parked in a live turn.
///
/// The request is answered with Allow or Deny through the turn-scoped steer
/// operation; [adapterCallbackTokenRef] identifies the parked route and is
/// never shown.
final class NativeApprovalRequest {
  NativeApprovalRequest({
    required this.agentId,
    required this.sessionId,
    required this.turnId,
    required this.adapterCallbackTokenRef,
    required this.pendingOperationId,
    required this.summary,
    Iterable<String> requestedTools = const <String>[],
  }) : requestedTools = List<String>.unmodifiable(requestedTools);

  final String agentId;
  final String sessionId;
  final String turnId;
  final String adapterCallbackTokenRef;
  final String pendingOperationId;
  final String summary;
  final List<String> requestedTools;
}
