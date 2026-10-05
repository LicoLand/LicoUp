import 'package:licoup/src/presentation/presentation_semantics.dart';

/// What an evaluating Agent concluded about one suggestion.
///
/// The four values are the four honest outcomes of asking for a judgment: the
/// evidence was usable, the evaluator rejected it, the evaluator could not
/// decide, or no evaluation was produced at all. None of them is an
/// instruction.
enum SelectionEvaluation { usable, rejected, uncertain, missing }

/// What a promotion of this suggestion would be allowed to change.
///
/// A routing-only sample measured one candidate order. It says nothing about
/// context handling or collaboration, so it may never be shown as a general
/// improvement to either.
enum SelectionPromotionSubject { routingOnly, routingAndContext }

/// One recorded suggestion, with everything a user needs before approving it.
final class SelectionSuggestionView {
  SelectionSuggestionView({
    required this.suggestionId,
    required this.evaluatorId,
    required this.evaluation,
    required this.rationale,
    required this.evidenceDigest,
    required this.evidenceLimits,
    required this.promotionSubject,
    required Iterable<String> proposedEffects,
    this.invalidated = false,
  }) : proposedEffects = immutablePresentationList(proposedEffects);

  final String suggestionId;

  /// The Agent that judged this suggestion. Attribution is never dropped.
  final String evaluatorId;

  final SelectionEvaluation evaluation;

  /// The evaluator's own words, shown verbatim.
  final String rationale;

  /// The bounded evidence digest the judgment was made against.
  final String evidenceDigest;

  /// What the evidence does not cover. Shown before approval, not after.
  final String evidenceLimits;

  final SelectionPromotionSubject promotionSubject;

  /// The future effects a promotion would have, as the proposal stated them.
  final List<String> proposedEffects;

  /// Whether a newer outcome already invalidated this suggestion.
  final bool invalidated;

  /// Whether approving this suggestion may change the policy at all.
  ///
  /// Only a usable evaluation proposes a change; a rejected, uncertain or
  /// missing evaluation is evidence about the sample, not a proposal.
  bool get proposesPolicyChange => evaluation == SelectionEvaluation.usable;

  /// Whether this suggestion may speak to context or collaboration as well as
  /// to the route.
  bool get speaksToContext =>
      promotionSubject == SelectionPromotionSubject.routingAndContext;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SelectionSuggestionView &&
          other.suggestionId == suggestionId &&
          other.evaluatorId == evaluatorId &&
          other.evaluation == evaluation &&
          other.rationale == rationale &&
          other.evidenceDigest == evidenceDigest &&
          other.evidenceLimits == evidenceLimits &&
          other.promotionSubject == promotionSubject &&
          samePresentationList(other.proposedEffects, proposedEffects) &&
          other.invalidated == invalidated;

  @override
  int get hashCode => Object.hash(
    suggestionId,
    evaluatorId,
    evaluation,
    rationale,
    evidenceDigest,
    evidenceLimits,
    promotionSubject,
    Object.hashAll(proposedEffects),
    invalidated,
  );

  @override
  String toString() =>
      'SelectionSuggestionView($suggestionId, $evaluation, $evaluatorId)';
}

/// The policy in force and the suggestions that may change it.
final class SelectionPolicyView {
  SelectionPolicyView({
    required this.revisionInForce,
    required Iterable<SelectionSuggestionView> suggestions,
    required this.phase,
    this.notice,
  }) : suggestions = immutablePresentationList(suggestions);

  /// The revision in force, or the unadopted marker when none is.
  final String revisionInForce;

  final List<SelectionSuggestionView> suggestions;

  final PresentationPhase phase;

  final PresentationNotice? notice;

  /// Whether an adopted policy is visible and may therefore be revoked.
  bool get hasAdoptedPolicy => revisionInForce.trim().isNotEmpty;

  /// The suggestions that may change the policy if the user approves one.
  List<SelectionSuggestionView> get actionableSuggestions => [
    for (final suggestion in suggestions)
      if (suggestion.proposesPolicyChange && !suggestion.invalidated) suggestion,
  ];

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SelectionPolicyView &&
          other.revisionInForce == revisionInForce &&
          samePresentationList(other.suggestions, suggestions) &&
          other.phase == phase &&
          other.notice == notice;

  @override
  int get hashCode => Object.hash(
    revisionInForce,
    Object.hashAll(suggestions),
    phase,
    notice,
  );

  @override
  String toString() =>
      'SelectionPolicyView($revisionInForce, '
      'suggestions=${suggestions.length}, $phase)';
}

/// The result of one explicit policy action.
///
/// A refusal carries the reason code the durable owner reported instead of
/// pretending the action happened.
final class SelectionPolicyOutcome {
  const SelectionPolicyOutcome._(this.accepted, this.reasonCode);

  const SelectionPolicyOutcome.accepted() : this._(true, '');

  const SelectionPolicyOutcome.refused(String reasonCode)
    : this._(false, reasonCode);

  final bool accepted;

  /// The refusal reason code, or an empty string when the action was accepted.
  final String reasonCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SelectionPolicyOutcome &&
          other.accepted == accepted &&
          other.reasonCode == reasonCode;

  @override
  int get hashCode => Object.hash(accepted, reasonCode);

  @override
  String toString() => accepted
      ? 'SelectionPolicyOutcome.accepted'
      : 'SelectionPolicyOutcome.refused($reasonCode)';
}

/// The reason code reported when no durable policy owner is composed.
const String selectionPolicyOwnerAbsentCode = 'selection_policy_owner_absent';

/// The actions a selection surface may take.
///
/// The surface calls these; it never writes a collection, a file or a register
/// itself, so a policy can only change through the owner that owns it. Every
/// action is explicit and none of them carries a run or task identity: a
/// promotion governs the *next* task and never rewrites an in-flight one.
abstract interface class SelectionPolicyActions {
  /// Approve a suggestion, after the user has seen its evidence.
  Future<SelectionPolicyOutcome> adopt(String suggestionId);

  /// Dismiss a suggestion. The current policy stays in force.
  Future<SelectionPolicyOutcome> dismiss(String suggestionId);

  /// Revoke the visible adopted policy, restoring its recorded predecessor.
  Future<SelectionPolicyOutcome> revoke(String revisionInForce);
}

/// Fail-closed actions for a host that composes no policy owner.
///
/// Nothing is written and nothing is adopted; the refusal is explicit so a
/// surface shows "no owner" instead of a silent success.
final class UnavailableSelectionPolicyActions
    implements SelectionPolicyActions {
  const UnavailableSelectionPolicyActions();

  @override
  Future<SelectionPolicyOutcome> adopt(String suggestionId) async =>
      const SelectionPolicyOutcome.refused(selectionPolicyOwnerAbsentCode);

  @override
  Future<SelectionPolicyOutcome> dismiss(String suggestionId) async =>
      const SelectionPolicyOutcome.accepted();

  @override
  Future<SelectionPolicyOutcome> revoke(String revisionInForce) async =>
      const SelectionPolicyOutcome.refused(selectionPolicyOwnerAbsentCode);
}
