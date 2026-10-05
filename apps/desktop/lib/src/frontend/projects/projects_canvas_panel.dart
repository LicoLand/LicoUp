import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/binding/effect_listener.dart';
import 'package:licoup/src/frontend/binding/projection_builder.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/projects/project_plan_submission.dart';
import 'package:licoup/src/frontend/projects/project_scoped_controls.dart';
import 'package:licoup/src/frontend/projects/projects_canvas_view.dart';
import 'package:licoup/src/frontend/projects/projects_list_view.dart';
import 'package:licoup/src/frontend/shared/ui/lico_empty_state.dart';
import 'package:licoup/src/frontend/shared/ui/lico_pane_scaffold.dart';
import 'package:licoup/src/frontend/shared/ui/lico_toast.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/projects/projects_binding.dart';
import 'package:licoup/src/presentation/projects/projects_effect.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/presentation/projects/projects_layout.dart';
import 'package:licoup/src/presentation/projects/projects_projection.dart';
import 'package:licoup/src/presentation/projects/projects_view.dart';

/// Which local view of the same facts this surface shows.
enum ProjectsSurfaceView { canvas, list }

/// The mounted project surface.
///
/// The panel is the only place that reads the feature's projections: it derives
/// the narrow [ProjectsListViewInputs] and [ProjectsCanvasViewInputs] from the
/// two sources and hands each view the actions it may reach. The canvas view
/// receives a card mover that writes the local arrangement; the list view
/// receives a reorder that does the same. Neither view can reach the intent
/// sink, the gateway or the controller.
///
/// Selecting a card and switching between the two views are local: they send no
/// intent, so no command follows from either, and the facts both views render
/// are the identical list the projection published.
final class ProjectsCanvasPanel extends StatefulWidget {
  const ProjectsCanvasPanel({
    super.key,
    required this.binding,
    this.submission = const UnconvertedProjectPlan(),
  });

  final ProjectsBinding binding;

  /// The caller-converted document this surface may submit, or none.
  final ProjectPlanSubmission submission;

  @override
  State<ProjectsCanvasPanel> createState() => _ProjectsCanvasPanelState();
}

final class _ProjectsCanvasPanelState extends State<ProjectsCanvasPanel> {
  late final ProjectsActions _actions;
  late final ProjectLayoutActions _layoutActions;
  ProjectsSurfaceView _view = ProjectsSurfaceView.canvas;
  String _projectId = '';
  String _selectedKey = '';
  bool _requestedRead = false;

  @override
  void initState() {
    super.initState();
    _actions = ProjectsActions.fromIntents(widget.binding.intents);
    _layoutActions = ProjectLayoutActions.fromMutations(
      widget.binding.layoutMutations,
    );
    // Opening the surface reads the durable facts once. The read is a read: it
    // submits no document, inserts nothing and starts no work.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _requestedRead) return;
      _requestedRead = true;
      _actions.refresh();
    });
  }

  @override
  Widget build(BuildContext context) => EffectListener<ProjectsEffect>(
    source: widget.binding.effects,
    onEffect: (effect) => _handleEffect(context, effect),
    child: ProjectionBuilder<ProjectsProjection, ProjectsProjection>(
      source: widget.binding.projection,
      select: (projection) => projection,
      builder: (context, projection) =>
          ProjectionBuilder<ProjectsLayoutState, ProjectsLayoutState>(
            source: widget.binding.layout,
            select: (layout) => layout,
            builder: (context, layout) =>
                _buildSurface(context, projection, layout),
          ),
    ),
  );

  Widget _buildSurface(
    BuildContext context,
    ProjectsProjection projection,
    ProjectsLayoutState layout,
  ) {
    final strings = LicoStrings.of(context);
    final listInputs = ProjectsListViewInputs.fromProjection(
      projection: projection,
      layout: layout,
      projectId: _projectId,
    );
    final canvasInputs = ProjectsCanvasViewInputs.fromProjection(
      projection: projection,
      layout: layout,
      projectId: _projectId,
    );
    return LicoPaneScaffold(
      key: const Key('projects-panel'),
      title: 'Projects',
      refreshTooltip: strings.refreshUsage,
      onRefresh: projection.phase == PresentationPhase.loading
          ? null
          : () => _actions.refresh(),
      refreshing: projection.phase == PresentationPhase.loading,
      refreshButtonKey: const Key('projects-refresh'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (projection.projects.length > 1)
            _ProjectSelector(
              projection: projection,
              projectId: listInputs.projectId,
              onSelect: (projectId) => setState(() {
                _projectId = projectId;
                _selectedKey = '';
              }),
            ),
          _ViewSwitch(
            view: _view,
            onSelect: (view) => setState(() => _view = view),
          ),
        ],
      ),
      body: _body(context, projection, listInputs, canvasInputs),
    );
  }

  Widget _body(
    BuildContext context,
    ProjectsProjection projection,
    ProjectsListViewInputs listInputs,
    ProjectsCanvasViewInputs canvasInputs,
  ) {
    final strings = LicoStrings.of(context);
    if (listInputs.card == null) {
      final notice = projection.notice;
      final code = projection.failureCode;
      return LicoEmptyState(
        key: const Key('projects-empty'),
        icon: Icons.account_tree_outlined,
        title: 'No project facts',
        message: notice == null
            ? ProjectImportDisclosure.lines(strings).join(' ')
            : '${notice.message}'
                  '${code.isEmpty || code == notice.message ? '' : ' ($code)'}',
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: switch (_view) {
            ProjectsSurfaceView.canvas => ProjectsCanvasView(
              inputs: canvasInputs,
              selectedKey: _selectedKey,
              onSelect: (key) => setState(() => _selectedKey = key),
              onMoveCard:
                  ({
                    required String projectId,
                    required String workItemId,
                    required double x,
                    required double y,
                  }) => _layoutActions.moveCard(
                    projectId: projectId,
                    workItemId: workItemId,
                    x: x,
                    y: y,
                  ),
            ),
            ProjectsSurfaceView.list => ProjectsListView(
              inputs: listInputs,
              selectedKey: _selectedKey,
              onSelect: (key) => setState(() => _selectedKey = key),
              onReorder: (keys) => _layoutActions.reorder(keys),
            ),
          },
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 320,
          child: ProjectScopedControls(
            inputs: canvasInputs,
            selectedKey: _selectedKey,
            actions: _actions,
            submission: widget.submission,
          ),
        ),
      ],
    );
  }

  void _handleEffect(BuildContext context, ProjectsEffect effect) {
    switch (effect) {
      case ProjectPlanPreviewed(
        :final planId,
        :final revision,
        :final replayed,
        :final addedCount,
        :final unchangedCount,
        :final retainedCount,
      ):
        showLicoToast(
          context,
          message:
              'Preview of $planId at revision $revision: $addedCount added, '
              '$unchangedCount unchanged, $retainedCount retained'
              '${replayed ? ' (the stored revision)' : ''}. Nothing was '
              'inserted.',
        );
      case ProjectPlanApplied(:final planId, :final revision, :final applied):
        showLicoToast(
          context,
          kind: applied ? LicoToastKind.success : LicoToastKind.info,
          message: applied
              ? 'Inserted the declared work of $planId at revision $revision.'
              : '$planId already held revision $revision; nothing changed.',
        );
      case ProjectDependentsIdentified(
        :final workItemId,
        :final dependentCount,
      ):
        showLicoToast(
          context,
          message: '$workItemId affects $dependentCount consumer(s).',
        );
      case ProjectRequestRejected(
        :final operation,
        :final reasonCode,
        :final recovery,
      ):
        showLicoToast(
          context,
          kind: LicoToastKind.error,
          message:
              '$operation was refused: $reasonCode'
              '${recovery.isEmpty ? '' : ' ($recovery)'}',
        );
    }
  }
}

final class _ViewSwitch extends StatelessWidget {
  const _ViewSwitch({required this.view, required this.onSelect});

  final ProjectsSurfaceView view;
  final ValueChanged<ProjectsSurfaceView> onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    Widget button({
      required Key key,
      required IconData icon,
      required String tooltip,
      required ProjectsSurfaceView value,
    }) => IconButton(
      key: key,
      tooltip: tooltip,
      onPressed: () => onSelect(value),
      icon: Icon(
        icon,
        size: 18,
        color: view == value ? colors.accent : colors.textMuted,
      ),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        button(
          key: const Key('projects-view-canvas'),
          icon: Icons.account_tree_outlined,
          tooltip: 'Canvas view',
          value: ProjectsSurfaceView.canvas,
        ),
        button(
          key: const Key('projects-view-list'),
          icon: Icons.list_alt_outlined,
          tooltip: 'List view',
          value: ProjectsSurfaceView.list,
        ),
      ],
    );
  }
}

final class _ProjectSelector extends StatelessWidget {
  const _ProjectSelector({
    required this.projection,
    required this.projectId,
    required this.onSelect,
  });

  final ProjectsProjection projection;
  final String projectId;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    key: const Key('projects-project-selector'),
    tooltip: 'Select project',
    onSelected: onSelect,
    itemBuilder: (context) => <PopupMenuEntry<String>>[
      for (final project in projection.projects)
        PopupMenuItem<String>(
          key: Key('projects-project-${project.projectId}'),
          value: project.projectId,
          child: Text(project.displayName),
        ),
    ],
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Text(
        projection.project(projectId)?.displayName ?? '',
        style: TextStyle(color: context.licoColors.textMuted, fontSize: 12),
      ),
    ),
  );
}
