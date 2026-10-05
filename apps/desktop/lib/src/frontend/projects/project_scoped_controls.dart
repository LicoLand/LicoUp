import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/project_plan_document.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/projects/project_plan_submission.dart';
import 'package:licoup/src/frontend/projects/project_work_item_card.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/projects/projects_projection.dart';
import 'package:licoup/src/presentation/projects/projects_view.dart';

/// The scoped controls of one selected work item.
///
/// The panel offers exactly the durable operations the project command family
/// publishes for a declaration — preview a caller-converted document, then
/// insert it over the revision that preview reported — and states plainly what
/// it cannot do. It holds no gateway and no controller: every command leaves
/// through [ProjectsActions], and every control that has no native operation
/// behind it renders an explicit absence instead of a button that pretends.
///
/// Nothing here starts work. A change is inserted only after the preview
/// reported what it would change and a person confirmed that exact revision,
/// and the stop and handoff sections send nothing at all.
final class ProjectScopedControls extends StatelessWidget {
  const ProjectScopedControls({
    super.key,
    required this.inputs,
    required this.selectedKey,
    required this.actions,
    this.submission = const UnconvertedProjectPlan(),
  });

  final ProjectsCanvasViewInputs inputs;

  /// The locally selected work item, or '' when none is selected.
  final String selectedKey;

  /// The durable project operations this surface may reach.
  final ProjectsActions actions;

  /// The caller-converted document this surface may preview and insert.
  final ProjectPlanSubmission submission;

  ProjectWorkItemFacts? get _selected {
    for (final facts in inputs.facts) {
      if (facts.key == selectedKey) return facts;
    }
    return null;
  }

  /// The newest previewed receipt for [planId], or null when none was read.
  ProjectImportReceiptProjection? _preview(String planId) {
    final receipts =
        inputs.card?.importReceipts ?? const <ProjectImportReceiptProjection>[];
    for (final receipt in receipts.reversed) {
      if (receipt.kind == ProjectImportReceiptKind.previewed &&
          (planId.isEmpty || receipt.planId == planId)) {
        return receipt;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    final selected = _selected;
    final document = submission.convertedDocument;
    final documentForProject =
        document != null && document.projectId == inputs.projectId
        ? document
        : null;
    final preview = _preview(documentForProject?.planId ?? '');
    return SingleChildScrollView(
      key: const Key('project-scoped-controls'),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            'Scoped controls',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: colors.text,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            selected == null
                ? 'Select a work item to scope these controls.'
                : 'Selected: ${selected.workItemId}',
            style: TextStyle(color: colors.textSecondary, fontSize: 12),
          ),
          const SizedBox(height: 10),
          _ChangeSection(
            actions: actions,
            projectId: inputs.projectId,
            documentForProject: documentForProject,
            preview: preview,
            facts: inputs.facts,
            selected: selected,
            strings: strings,
          ),
          const SizedBox(height: 12),
          _StopSection(
            facts: selected == null
                ? inputs.facts
                : <ProjectWorkItemFacts>[selected],
            actions: actions,
            strings: strings,
          ),
          const SizedBox(height: 12),
          const _HandoffSection(),
          const SizedBox(height: 12),
          _ImportDisclosure(strings: strings),
        ],
      ),
    );
  }
}

/// Preview a converted document, then insert it over the previewed revision.
final class _ChangeSection extends StatelessWidget {
  const _ChangeSection({
    required this.actions,
    required this.projectId,
    required this.documentForProject,
    required this.preview,
    required this.facts,
    required this.selected,
    required this.strings,
  });

  final ProjectsActions actions;
  final String projectId;
  final ProjectPlanDocument? documentForProject;
  final ProjectImportReceiptProjection? preview;
  final List<ProjectWorkItemFacts> facts;
  final ProjectWorkItemFacts? selected;
  final LicoStrings strings;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final converted = documentForProject;
    final receipt = preview;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          'Change preview and insert',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: colors.text,
            fontSize: 12,
          ),
        ),
        const SizedBox(height: 4),
        if (converted case final document?) ...<Widget>[
          Text(
            'Converted document: ${document.projectId}/${document.planId} '
            '(${document.workItems.length} declared items).',
            style: TextStyle(color: colors.textMuted, fontSize: 11),
          ),
          const SizedBox(height: 6),
          OutlinedButton(
            key: const Key('project-preview-change'),
            onPressed: () => actions.previewImport(document),
            child: const Text('Preview change'),
          ),
        ] else
          Text(
            strings.localized(
              ProjectImportDisclosure.noImporterKey,
              strings.isChinese
                  ? ProjectImportDisclosure.noImporterTextZh
                  : ProjectImportDisclosure.noImporterText,
            ),
            key: const Key('project-no-converted-document'),
            style: TextStyle(color: colors.textMuted, fontSize: 11),
          ),
        const SizedBox(height: 6),
        if (receipt == null)
          Text(
            'Insert stays unavailable until a preview reports what this '
            'document would change.',
            key: const Key('project-insert-requires-preview'),
            style: TextStyle(color: colors.textMuted, fontSize: 11),
          )
        else if (converted case final document?) ...<Widget>[
          Text(
            'Previewed, not applied: revision ${receipt.revision} '
            '(${receipt.added.length} added, ${receipt.unchanged.length} '
            'unchanged, ${receipt.retained.length} retained). '
            'Nothing is inserted until you confirm.',
            key: const Key('project-change-confirmation'),
            style: TextStyle(color: colors.textSecondary, fontSize: 11),
          ),
          const SizedBox(height: 6),
          _AffectedWork(
            keyPrefix: 'project-change',
            title: 'Affected work',
            facts: facts,
            actions: actions,
            workItemIds: <String>[
              ...receipt.added,
              ...receipt.unchanged,
              ...receipt.retained,
            ],
            emptyMessage:
                'This document names no work item this project holds.',
          ),
          const SizedBox(height: 6),
          FilledButton(
            key: const Key('project-confirm-insert'),
            onPressed: () => actions.applyImport(
              document,
              expectedRevision: receipt.revision,
            ),
            child: const Text('Insert declared work'),
          ),
        ],
      ],
    );
  }
}

/// One work item's real dependents, or the explicit absence of that read.
final class _AffectedWork extends StatelessWidget {
  const _AffectedWork({
    required this.keyPrefix,
    required this.title,
    required this.facts,
    required this.actions,
    required this.workItemIds,
    required this.emptyMessage,
  });

  /// Prefix that keeps one section's keys distinct from the other's.
  final String keyPrefix;

  final String title;
  final List<ProjectWorkItemFacts> facts;
  final ProjectsActions actions;
  final List<String> workItemIds;
  final String emptyMessage;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final affected = <ProjectWorkItemFacts>[];
    for (final id in workItemIds) {
      for (final candidate in facts) {
        if (candidate.workItemId == id && !affected.contains(candidate)) {
          affected.add(candidate);
        }
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          title,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: colors.text,
            fontSize: 12,
          ),
        ),
        if (affected.isEmpty)
          Text(
            emptyMessage,
            style: TextStyle(color: colors.textMuted, fontSize: 11),
          ),
        for (final candidate in affected) ...<Widget>[
          const SizedBox(height: 4),
          Text(
            '${candidate.workItemId}: '
            '${ProjectFactLabels.blocking(candidate.blockingReason)}; '
            '${ProjectFactLabels.dependents(candidate.dependents)}',
            key: Key('$keyPrefix-affected-${candidate.workItemId}'),
            style: TextStyle(color: colors.textMuted, fontSize: 11),
          ),
          if (!candidate.dependents.observed)
            TextButton(
              key: Key('$keyPrefix-read-dependents-${candidate.workItemId}'),
              onPressed: () => actions.inspectDependents(
                projectId: candidate.projectId,
                workItemId: candidate.workItemId,
              ),
              child: const Text('Read affected consumers'),
            ),
        ],
      ],
    );
  }
}

/// The stop an operator expects on a work surface, and its real disposition.
///
/// Stopping admitted work is a work-control operation addressed by a durable
/// work identity — a conversation turn, a workflow run, a subagent claim or a
/// supervised lane session. No project route publishes a run or an owner
/// identity, and this projection deliberately observes none, so the panel
/// states what is affected and sends nothing.
final class _StopSection extends StatelessWidget {
  const _StopSection({
    required this.facts,
    required this.actions,
    required this.strings,
  });

  final List<ProjectWorkItemFacts> facts;
  final ProjectsActions actions;
  final LicoStrings strings;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          'Stop',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: colors.text,
            fontSize: 12,
          ),
        ),
        Text(
          'The project command family publishes no stop route and no run, so '
          'this surface holds no work identity to stop and sends no signal. '
          'Stopping admitted work belongs to the work-control lane of the work '
          'owner that observed it.',
          key: const Key('project-stop-unavailable'),
          style: TextStyle(color: colors.textMuted, fontSize: 11),
        ),
        const SizedBox(height: 6),
        _AffectedWork(
          keyPrefix: 'project-stop',
          title: 'Work this item affects',
          facts: facts,
          actions: actions,
          workItemIds: <String>[for (final item in facts) item.workItemId],
          emptyMessage: 'No work item is scoped here.',
        ),
      ],
    );
  }
}

/// Handing declared work to an executor, and its real disposition.
final class _HandoffSection extends StatelessWidget {
  const _HandoffSection();

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          'Hand off',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: colors.text,
            fontSize: 12,
          ),
        ),
        Text(
          'Handing a declaration to an executor is not a project operation: no '
          'project route publishes an executor identity, a run or a handoff. '
          'This surface therefore offers no handoff control and claims none.',
          key: const Key('project-handoff-unavailable'),
          style: TextStyle(color: colors.textMuted, fontSize: 11),
        ),
      ],
    );
  }
}

/// The incomplete-import statement, rendered on every project surface.
final class _ImportDisclosure extends StatelessWidget {
  const _ImportDisclosure({required this.strings});

  final LicoStrings strings;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Container(
      key: const Key('project-import-disclosure'),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: colors.surfaceSunken,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final line in ProjectImportDisclosure.lines(strings))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                line,
                style: TextStyle(color: colors.textMuted, fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }
}
