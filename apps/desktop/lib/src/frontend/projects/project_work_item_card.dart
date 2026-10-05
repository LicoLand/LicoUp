import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/projects/projects_projection.dart';

/// Renderer-facing labels for the projected project facts.
///
/// Every label states what the facts say, including the absences: a run, a
/// completion or an acceptance this client did not observe is rendered as not
/// observed, never as an empty or successful state.
abstract final class ProjectFactLabels {
  static String declaration(ProjectDeclarationState state) => switch (state) {
    ProjectDeclarationState.held => 'declared',
    ProjectDeclarationState.notHeld => 'not declared here',
  };

  static String membership(ProjectDurableMembership membership) =>
      switch (membership) {
        ProjectDurableMembership.added => 'added by the last applied import',
        ProjectDurableMembership.unchanged => 'already held',
        ProjectDurableMembership.retained => 'retained; the document omits it',
        ProjectDurableMembership.notObserved => 'membership not observed',
      };

  static String inputState(ProjectInputState state) => switch (state) {
    ProjectInputState.materialized => 'materialized',
    ProjectInputState.missing => 'missing',
    ProjectInputState.unavailable => 'unavailable',
    ProjectInputState.notApplied => 'declared, not applied',
  };

  static String blocking(ProjectBlockingReason reason) => switch (reason) {
    ProjectBlockingReason.none => 'nothing declared blocks this',
    ProjectBlockingReason.missingArtifact =>
      'a declared result does not exist at the declared location',
    ProjectBlockingReason.unavailableArtifact =>
      'a declared location cannot be reached inside the declared authority',
    ProjectBlockingReason.unappliedInput =>
      'a declared input was never applied, so its result was not read',
    ProjectBlockingReason.notObserved =>
      'declared inputs were not read for this project',
  };

  /// The one line that states the three runtime absences.
  ///
  /// The project command family publishes no run, no completion and no
  /// acceptance, so a renderer must show that absence rather than read silence
  /// as a status.
  static const String runtimeNotObserved =
      'run / completion / acceptance: not observed';

  static String dependents(ProjectDependentsFacts facts) => facts.observed
      ? facts.dependents.isEmpty
            ? 'blocks nothing this client read'
            : 'blocks ${facts.dependents.map((ref) => ref.toString()).join(', ')}'
      : 'dependents not observed';

  static String inputs(ProjectDeclaredInputsFacts facts) => !facts.observed
      ? 'declared inputs: not observed'
      : facts.inputs.isEmpty
      ? 'declared inputs: none'
      : 'declared inputs: ${facts.inputs.map((input) => '${input.artifactLabel} (${inputState(input.state)})').join(', ')}';
}

/// One work item's facts, and nothing else.
///
/// The card renders the same [ProjectWorkItemFacts] the list view and the graph
/// view read, so the declared result, the blocking reason and the real
/// dependents cannot disagree between views. It carries no coordinate of its
/// own and offers no action: every command stays with the surface that scopes
/// it to a selected work item.
final class ProjectWorkItemCard extends StatelessWidget {
  const ProjectWorkItemCard({
    super.key,
    required this.facts,
    this.selected = false,
    this.onTap,
  });

  final ProjectWorkItemFacts facts;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Material(
      color: selected ? colors.selectedSurface : colors.surfaceLow,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        key: Key('project-work-item-${facts.workItemId}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? colors.accentBorder : colors.line,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      facts.workItemId,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: colors.text,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  Text(
                    ProjectFactLabels.declaration(facts.declarationState),
                    style: TextStyle(color: colors.textMuted, fontSize: 10),
                  ),
                ],
              ),
              if (facts.declaredOutcome.isNotEmpty)
                Text(
                  facts.declaredOutcome,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colors.textSecondary, fontSize: 11),
                ),
              _FactLine(
                maxLines: 2,
                text:
                    'blocking: '
                    '${ProjectFactLabels.blocking(facts.blockingReason)}',
              ),
              _FactLine(text: ProjectFactLabels.dependents(facts.dependents)),
              _FactLine(text: ProjectFactLabels.inputs(facts.inputs)),
              _FactLine(
                text:
                    'membership: '
                    '${ProjectFactLabels.membership(facts.durableMembership)}',
              ),
              const _FactLine(text: ProjectFactLabels.runtimeNotObserved),
            ],
          ),
        ),
      ),
    );
  }
}

final class _FactLine extends StatelessWidget {
  const _FactLine({required this.text, this.maxLines = 1});

  final String text;

  /// Lines this fact may occupy. A graph node has one row of space per fact,
  /// so a fact that does not fit is elided rather than drawn over its
  /// neighbour.
  final int maxLines;

  @override
  Widget build(BuildContext context) => Text(
    text,
    maxLines: maxLines,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(
      color: context.licoColors.textMuted,
      fontSize: 10,
      height: 1.2,
    ),
  );
}
