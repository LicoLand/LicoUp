import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/contracts/collaboration_run_models.dart';
import 'package:licoup/src/contracts/collaboration_run_port.dart';
import 'package:licoup/src/presentation/collaboration/collaboration_effect.dart';
import 'package:licoup/src/presentation/collaboration/collaboration_intent.dart';
import 'package:licoup/src/presentation/collaboration/collaboration_projection.dart';
import 'package:licoup/src/projections/collaboration/collaboration_projection_producer.dart';

/// Per-conversation collaboration source over the reserved run port.
///
/// Subscribes to `port.watchConversation` at construction, keeps the latest
/// snapshot plus the viewed revision, and translates
/// [CollaborationIntent]s into port commands. Commands carry the current head
/// as `expectedHead`; conflicts and rejections surface as effects. An
/// observation error marks the projection unavailable until the next
/// snapshot.
final class CollaborationPresentationSource
    implements
        ProjectionSource<CollaborationProjection>,
        IntentSink<CollaborationIntent>,
        EffectSource<CollaborationEffect> {
  CollaborationPresentationSource({
    required CollaborationRunPort port,
    required String conversationId,
  }) : _port = port,
       _conversationId = conversationId {
    _subscription = _port
        .watchConversation(_conversationId)
        .listen(_accept, onError: _acceptError);
  }

  final CollaborationRunPort _port;
  final String _conversationId;
  late final StreamSubscription<CollaborationRunSnapshot?> _subscription;

  final StreamController<ProjectionUpdate<CollaborationProjection>> _changes =
      StreamController<ProjectionUpdate<CollaborationProjection>>.broadcast(
        sync: true,
      );
  final StreamController<CollaborationEffect> _effects =
      StreamController<CollaborationEffect>.broadcast(sync: true);

  CollaborationRunSnapshot? _snapshot;
  bool _unavailable = false;
  int? _viewedNumber;
  CollaborationGraph? _viewedGraph;

  /// Incremented by every revision selection so a slower, superseded load
  /// cannot replace the revision the user selected last.
  int _selection = 0;
  int _commandsInFlight = 0;
  CollaborationProjection _current = CollaborationProjection.loading();
  bool _disposed = false;

  @override
  CollaborationProjection get current => _current;

  @override
  Stream<ProjectionUpdate<CollaborationProjection>> get changes =>
      _changes.stream;

  @override
  Stream<CollaborationEffect> get effects => _effects.stream;

  @override
  void send(CollaborationIntent intent) {
    if (_disposed) return;
    switch (intent) {
      case SelectCollaborationRevision(:final number):
        unawaited(_selectRevision(number, trace: intent.trace));
      case ApproveCollaborationProposal():
        _sendProposalCommand(
          (number, head) => ApproveProposal(number: number, expectedHead: head),
          trace: intent.trace,
        );
      case RejectCollaborationProposal():
        _sendProposalCommand(
          (number, head) => RejectProposal(number: number, expectedHead: head),
          trace: intent.trace,
        );
      case RequestCollaborationRevision(:final note):
        _sendProposalCommand(
          (number, head) =>
              RequestRevision(number: number, note: note, expectedHead: head),
          trace: intent.trace,
        );
      case RevertCollaborationRevision(:final number):
        _sendCommand(
          (run, head) => RevertTo(number: number, expectedHead: head),
          trace: intent.trace,
        );
      case DecideCollaborationGate(:final gateId, :final optionId):
        _sendCommand(
          (run, head) => DecideGate(
            gateId: gateId,
            optionId: optionId,
            expectedHead: head,
          ),
          trace: intent.trace,
        );
      case SetCollaborationPlanChangePolicy(:final policy):
        _sendCommand(
          (run, head) =>
              SetPlanChangePolicy(policy: policy, expectedHead: head),
          trace: intent.trace,
        );
      case SetCollaborationGateReviewPolicy(:final policy):
        _sendCommand(
          (run, head) =>
              SetGateReviewPolicy(policy: policy, expectedHead: head),
          trace: intent.trace,
        );
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _subscription.cancel();
    await _changes.close();
    await _effects.close();
  }

  void _accept(CollaborationRunSnapshot? snapshot) {
    if (_disposed) return;
    final previousRun = _snapshot?.runId;
    _snapshot = snapshot;
    _unavailable = false;
    // A committed change may render the viewed historical revision stale;
    // the viewed graph stays until the user selects another revision or
    // returns to the head. A different run invalidates it.
    if (snapshot == null ||
        snapshot.runId != previousRun ||
        _viewedNumber == snapshot.headNumber) {
      _clearViewedRevision();
    }
    _emit();
  }

  void _acceptError(Object error) {
    if (_disposed) return;
    _snapshot = null;
    _unavailable = true;
    _clearViewedRevision();
    _emit();
  }

  void _clearViewedRevision() {
    _selection++;
    _viewedNumber = null;
    _viewedGraph = null;
  }

  Future<void> _selectRevision(int? number, {TraceContext? trace}) async {
    final selection = ++_selection;
    final snapshot = _snapshot;
    if (number == null || number == snapshot?.headNumber) {
      _viewedNumber = null;
      _viewedGraph = null;
      _emit();
      return;
    }
    if (snapshot == null) return;
    try {
      final graph = await _port.loadRevision(snapshot.runId, number);
      if (_disposed || selection != _selection) return;
      _viewedNumber = number;
      _viewedGraph = graph;
      _emit();
    } catch (error) {
      if (_disposed || selection != _selection) return;
      _effects.add(
        CollaborationCommandRejected(_errorCode(error), trace: trace),
      );
    }
  }

  void _sendProposalCommand(
    CollaborationCommand Function(int number, int head) build, {
    TraceContext? trace,
  }) {
    _sendCommand((run, head) {
      final proposal = run.proposal;
      if (proposal == null) return null;
      return build(proposal.revision.number, head);
    }, trace: trace);
  }

  void _sendCommand(
    CollaborationCommand? Function(CollaborationRunSnapshot run, int head)
    build, {
    TraceContext? trace,
  }) {
    final snapshot = _snapshot;
    if (snapshot == null) return;
    final command = build(snapshot, snapshot.headNumber);
    if (command == null) return;
    _commandsInFlight++;
    _emit();
    unawaited(_deliver(snapshot.runId, command, trace));
  }

  Future<void> _deliver(
    String runId,
    CollaborationCommand command,
    TraceContext? trace,
  ) async {
    CollaborationCommandResult result;
    try {
      result = await _port.send(runId, command);
    } catch (error) {
      result = CollaborationCommandResultRejected(_errorCode(error));
    }
    if (_disposed) return;
    _commandsInFlight--;
    _emit();
    switch (result) {
      case CollaborationCommandResultAccepted():
        break;
      case CollaborationCommandResultConflict(:final currentHead):
        _effects.add(CollaborationCommandConflicted(currentHead, trace: trace));
      case CollaborationCommandResultRejected(:final code):
        _effects.add(CollaborationCommandRejected(code, trace: trace));
    }
  }

  /// Only stable machine codes cross into effects; free-form error text from
  /// an adapter never reaches the renderer.
  String _errorCode(Object error) {
    final code = switch (error) {
      StateError(:final message) => message,
      FormatException(:final message) => message,
      _ => null,
    };
    if (code != null && _stableCode.hasMatch(code)) return code;
    return collaborationCommandFailed;
  }

  static final RegExp _stableCode = RegExp(r'^[a-z][a-z0-9_]{0,63}$');

  void _emit() {
    final next = collaborationProjection(
      snapshot: _snapshot,
      unavailable: _unavailable,
      viewedNumber: _viewedNumber,
      viewedGraph: _viewedGraph,
      commandPending: _commandsInFlight > 0,
    );
    if (next == _current) return;
    _current = next;
    _changes.add(ProjectionUpdate<CollaborationProjection>(next));
  }
}
