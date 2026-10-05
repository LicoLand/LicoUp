import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/features/models/selection/selection_facts_section.dart';
import 'package:licoup/src/frontend/features/models/selection/selection_policy_section.dart';
import 'package:licoup/src/frontend/features/models/selection/selection_policy_view.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/projections/model_selection/model_selection_projection.dart';

/// The reason code reported when the host composes no selection-facts source.
const String selectionFactsSourceAbsentCode = 'selection_facts_source_absent';

/// Where a mounted surface reads the selection policy it displays.
///
/// Reading is passive: it discloses which revision is in force and which
/// suggestions were recorded, and it changes nothing. An absent or unreadable
/// source reports a failed view with an explicit reason instead of an empty
/// successful one, so "could not read" is never rendered as "nothing adopted".
abstract interface class SelectionPolicySource {
  Future<SelectionPolicyView> read();
}

/// Where a mounted surface reads one Agent's route/support facts.
///
/// The same fail-closed rule applies: a host without a source reports the
/// projection's own failed phase with a reason code.
abstract interface class SelectionFactsSource {
  Future<ModelSelectionProjection> read(String agent);
}

/// The source a host composes when no selection-facts command exists yet.
///
/// The projection already models "could not read" as a failed phase carrying a
/// reason, so the absence is reported rather than guessed.
final class UnavailableSelectionFactsSource implements SelectionFactsSource {
  const UnavailableSelectionFactsSource();

  @override
  Future<ModelSelectionProjection> read(String agent) async =>
      ModelSelectionProjection(
        agent: agent,
        entries: const [],
        phase: PresentationPhase.failed,
        notice: const PresentationNotice(
          id: 'selection-facts-unavailable',
          title: 'Selection facts',
          message: 'The selection facts for this Agent could not be read.',
          severity: PresentationNoticeSeverity.error,
          reasonCode: selectionFactsSourceAbsentCode,
        ),
      );
}

/// The source a host composes when it composes no policy reader.
final class UnavailableSelectionPolicySource implements SelectionPolicySource {
  const UnavailableSelectionPolicySource();

  @override
  Future<SelectionPolicyView> read() async => SelectionPolicyView(
    revisionInForce: '',
    suggestions: const [],
    phase: PresentationPhase.failed,
    notice: const PresentationNotice(
      id: 'selection-policy-unavailable',
      title: 'Route selection policy',
      message: 'The selection policy could not be read.',
      severity: PresentationNoticeSeverity.error,
      reasonCode: selectionPolicyOwnerAbsentCode,
    ),
  );
}

/// The composed selection surfaces and the ports behind them.
///
/// This is the one place a selection surface is bound to its sources and its
/// actions. It deliberately owns no transition of its own: an action reaches
/// whichever [SelectionPolicyActions] the host composed, and the fail-closed
/// composition is the default so a build without a durable owner changes
/// nothing and says so.
final class SelectionPolicyComposition {
  const SelectionPolicyComposition({
    required this.policySource,
    required this.factsSource,
    required this.actions,
  });

  /// The composition a host builds while no selection command is mounted.
  ///
  /// Nothing is adopted, nothing is revoked, and no document is written: the
  /// client half is present and explicit about the missing owner instead of
  /// acting as a second implementer of the owner's transition.
  const SelectionPolicyComposition.unavailable()
    : policySource = const UnavailableSelectionPolicySource(),
      factsSource = const UnavailableSelectionFactsSource(),
      actions = const UnavailableSelectionPolicyActions();

  final SelectionPolicySource policySource;
  final SelectionFactsSource factsSource;
  final SelectionPolicyActions actions;

  /// Read the policy once, for a caller that renders it.
  Future<SelectionPolicyView> readPolicy() => policySource.read();

  /// Read one Agent's facts once, for a caller that renders them.
  Future<ModelSelectionProjection> readFacts(String agent) =>
      factsSource.read(agent);

  /// The policy surface for one already-read view.
  Widget policySection(SelectionPolicyView view) =>
      SelectionPolicySection(view: view, actions: actions);

  /// The facts surface for one already-read projection.
  Widget factsSection(ModelSelectionProjection projection) =>
      SelectionFactsSection(projection: projection);
}
