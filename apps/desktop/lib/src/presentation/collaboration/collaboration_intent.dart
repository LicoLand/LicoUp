import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/contracts/collaboration_run_models.dart';

sealed class CollaborationIntent {
  const CollaborationIntent({this.trace});

  final TraceContext? trace;
}

/// Selects which revision the flowchart renders. `null` returns to the head.
final class SelectCollaborationRevision extends CollaborationIntent {
  const SelectCollaborationRevision(this.number, {super.trace});

  final int? number;
}

/// Approves the held proposal (plan-change `ask` policy).
final class ApproveCollaborationProposal extends CollaborationIntent {
  const ApproveCollaborationProposal({super.trace});
}

/// Rejects the held proposal; the run stays on its head and the revision is
/// recorded as rejected.
final class RejectCollaborationProposal extends CollaborationIntent {
  const RejectCollaborationProposal({super.trace});
}

/// Asks the Assistant to revise the held proposal; [note] becomes a
/// Conversation message.
final class RequestCollaborationRevision extends CollaborationIntent {
  const RequestCollaborationRevision(this.note, {super.trace});

  final String note;
}

/// Creates a new revision whose content equals [number] (git-style revert).
final class RevertCollaborationRevision extends CollaborationIntent {
  const RevertCollaborationRevision(this.number, {super.trace});

  final int number;
}

final class DecideCollaborationGate extends CollaborationIntent {
  const DecideCollaborationGate(this.gateId, this.optionId, {super.trace});

  final String gateId;
  final String optionId;
}

final class SetCollaborationPlanChangePolicy extends CollaborationIntent {
  const SetCollaborationPlanChangePolicy(this.policy, {super.trace});

  final CollaborationPlanChangePolicy policy;
}

final class SetCollaborationGateReviewPolicy extends CollaborationIntent {
  const SetCollaborationGateReviewPolicy(this.policy, {super.trace});

  final CollaborationGateReviewPolicy policy;
}
