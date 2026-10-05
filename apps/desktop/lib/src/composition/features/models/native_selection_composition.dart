import 'package:licoup/src/composition/features/models/selection_policy_composition.dart';
import 'package:licoup/src/frontend/features/models/selection/selection_policy_view.dart';
import 'package:licoup/src/platform/native_client/native_cli_ports.dart';
import 'package:licoup/src/platform/native_client/native_selection_actions.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/projections/model_selection/model_selection_projection.dart';

/// The reason code reported when the host composes no suggestion source.
///
/// A suggestion is the evaluating Agent's evidence for a user decision, and this
/// host exposes the policy register and the selection matrix; it does not yet
/// expose a recorded suggestion. The policy read therefore says so instead of
/// reporting an empty successful list, which would read as "no suggestion was
/// ever recorded" — a claim nothing on this host made.
const String selectionSuggestionsSourceAbsentCode =
    'selection_suggestions_source_absent';

/// The reason code reported when a suggestion cannot be turned into a revision.
///
/// Approving a suggestion and adopting a revision are not the same act: the
/// owner adopts a *revision*, and the step that turns one evaluated suggestion
/// into a revision — its identity, its provenance and the preferences it
/// contributes — belongs to the producer of that suggestion. No such producer is
/// composed here, so approving one changes nothing and says why.
const String selectionSuggestionRevisionAbsentCode =
    'selection_suggestion_revision_absent';

/// Reads one Agent's selection facts through the native selection surface.
///
/// The matrix document is handed to the projection unchanged: the projection
/// owns the reading of that contract and already fails closed on a document it
/// cannot accept. A refusal — including `selection_matrix_unavailable` — becomes
/// the projection's own failed phase carrying the refusal's code, so "could not
/// look" is never rendered as "this Agent offers nothing".
final class NativeSelectionFactsSource implements SelectionFactsSource {
  const NativeSelectionFactsSource(this.actions);

  final NativeSelectionActions actions;

  @override
  Future<ModelSelectionProjection> read(String agent) async {
    try {
      final document = await actions.matrixDocument(agent);
      return ModelSelectionProjection.fromDocument(document, agent: agent);
    } on LicoClientRpcException catch (error) {
      return ModelSelectionProjection(
        agent: agent,
        entries: const <ModelSelectionViewItem>[],
        phase: PresentationPhase.failed,
        notice: PresentationNotice(
          id: 'selection-facts-unavailable',
          title: 'Selection facts',
          message: 'The selection facts for this Agent could not be read.',
          severity: PresentationNoticeSeverity.error,
          reasonCode: selectionRefusalCode(error).wireName,
        ),
      );
    }
  }
}

/// Reads the policy in force through the native selection surface.
///
/// The revision reported is the owner's binding, never a value this client
/// derives: an unadopted register reports the empty revision the surface renders
/// as "unadopted", so a reader is never shown a name for a policy that does not
/// exist.
///
/// The suggestion half of the view has no source yet, and that is stated: the
/// view carries a failed phase whose reason names the missing source while the
/// revision in force stays readable and revocable, because a reader who can see
/// the adopted policy can still retire it.
final class NativeSelectionPolicySource implements SelectionPolicySource {
  const NativeSelectionPolicySource(this.actions);

  final NativeSelectionActions actions;

  @override
  Future<SelectionPolicyView> read() async {
    try {
      final binding = await actions.policy();
      return SelectionPolicyView(
        revisionInForce: binding.revisionId ?? '',
        suggestions: const <SelectionSuggestionView>[],
        phase: PresentationPhase.failed,
        notice: const PresentationNotice(
          id: 'selection-suggestions-unavailable',
          title: 'Route selection policy',
          message: 'The recorded suggestions could not be read.',
          severity: PresentationNoticeSeverity.error,
          reasonCode: selectionSuggestionsSourceAbsentCode,
        ),
      );
    } on LicoClientRpcException catch (error) {
      return SelectionPolicyView(
        revisionInForce: '',
        suggestions: const <SelectionSuggestionView>[],
        phase: PresentationPhase.failed,
        notice: PresentationNotice(
          id: 'selection-policy-unavailable',
          title: 'Route selection policy',
          message: 'The selection policy could not be read.',
          severity: PresentationNoticeSeverity.error,
          reasonCode: selectionRefusalCode(error).wireName,
        ),
      );
    }
  }
}

/// The policy actions of a host that composes the native selection surface.
///
/// A revocation is the owner's own transition over the register it holds, so the
/// revision a reader saw is the revision that is revoked and the refusal the
/// owner reports is the refusal the surface shows. Nothing here writes client
/// state, and no action carries a run or task identity: a policy governs the
/// *next* task and never rewrites an in-flight one.
final class NativeSelectionPolicyActions implements SelectionPolicyActions {
  const NativeSelectionPolicyActions(this.actions);

  final NativeSelectionActions actions;

  /// Approving a suggestion adopts a revision, and no composed owner turns one
  /// into the other, so this refuses with the reason that says exactly that.
  @override
  Future<SelectionPolicyOutcome> adopt(String suggestionId) async =>
      const SelectionPolicyOutcome.refused(
        selectionSuggestionRevisionAbsentCode,
      );

  /// Dismissing a suggestion changes no policy: the revision in force stays in
  /// force, and nothing is written.
  @override
  Future<SelectionPolicyOutcome> dismiss(String suggestionId) async =>
      const SelectionPolicyOutcome.accepted();

  @override
  Future<SelectionPolicyOutcome> revoke(String revisionInForce) async {
    try {
      await actions.revoke(revisionInForce);
      return const SelectionPolicyOutcome.accepted();
    } on LicoClientRpcException catch (error) {
      return SelectionPolicyOutcome.refused(
        selectionRefusalCode(error).wireName,
      );
    }
  }
}

/// The selection surfaces a host binds to the native selection surface.
SelectionPolicyComposition nativeSelectionComposition(
  NativeSelectionActions actions,
) => SelectionPolicyComposition(
  policySource: NativeSelectionPolicySource(actions),
  factsSource: NativeSelectionFactsSource(actions),
  actions: NativeSelectionPolicyActions(actions),
);
