/// The native project collaboration board: project rail, causal swimlanes,
/// shared-gate anchors, node cards and the detail panel.
///
/// The widget renders one prepared value and never reads a source, a runtime or
/// a controller. Selection, expansion, filters, pan, zoom and lane order are
/// interface state; changing any of them cannot dispatch an action, mutate
/// execution or alter a count. Every action goes through one typed callback the
/// host owns, and a dispatched action stays visibly waiting until the host
/// reports the native receipt.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'graph_resource_details.dart';
import 'graph_view_state.dart';
import 'graph_view_strings.dart';

/// Content geometry shared by the board, the panel and the cards. These mirror
/// the interface design system: content cards 12, floating surfaces 10,
/// controls and chips 8, recessed wells 6, spacing on 4/8/16/24.
const double graphContentRadius = 12;
const double graphFloatingRadius = 10;
const double graphControlRadius = 8;
const double graphWellRadius = 6;
const double graphSpaceXs = 4;
const double graphSpaceSm = 8;
const double graphSpaceMd = 16;
const double graphSpaceLg = 24;

/// Below this width the surface uses the narrow header and callouts.
const double graphNarrowBreakpoint = 900;

/// One action the interface asks the host to perform.
///
/// The action reference is opaque to this widget: the host decides what it
/// means, whether it is allowed, and what the native owner answers.
@immutable
final class GraphActionRequest {
  const GraphActionRequest({
    required this.actionRef,
    this.nodeId,
    this.gateId,
    this.values = const <String, String>{},
  });

  final String actionRef;
  final String? nodeId;
  final String? gateId;
  final Map<String, String> values;

  /// Stable key of the in-flight receipt this request waits for.
  String get key => '$actionRef|${nodeId ?? gateId ?? ''}';

  @override
  String toString() => 'GraphActionRequest($actionRef, ${nodeId ?? gateId})';
}

/// Renders one prepared graph value with real project-collaboration controls.
class GraphResourceView extends StatefulWidget {
  const GraphResourceView({
    super.key,
    required this.value,
    this.initialState = const GraphViewState(),
    this.unavailableReason,
    this.pendingActions = const <String>{},
    this.onAction,
    this.onStateChanged,
    this.roles = const <String>[],
    this.narrowBreakpoint = 900,
  });

  /// The installed prepared value, or null while loading, withdrawn or
  /// unavailable.
  final GraphPreparedValue? value;

  final GraphViewState initialState;

  /// Why nothing can be shown, when the host knows.
  final String? unavailableReason;

  /// Action keys whose native receipt has not arrived yet.
  ///
  /// A control whose key is pending is disabled and labelled as waiting: the
  /// interface never shows a state the native owner has not confirmed.
  final Set<String> pendingActions;

  /// Dispatches one typed action to the host. Null when the contribution has no
  /// bound action port, in which case the controls are locally unavailable.
  final FutureOr<void> Function(GraphActionRequest request)? onAction;

  /// Notified after every interface-only state change.
  final ValueChanged<GraphViewState>? onStateChanged;

  /// Role pool ids present in the document, offered as a filter.
  final List<String> roles;

  final double narrowBreakpoint;

  @override
  State<GraphResourceView> createState() => GraphResourceViewState();
}

class GraphResourceViewState extends State<GraphResourceView> {
  late GraphViewState _state = widget.initialState;
  final ValueNotifier<GraphCardFocus> _cardFocus =
      ValueNotifier<GraphCardFocus>(GraphCardFocus.empty);
  final FocusNode _boardFocus = FocusNode(debugLabel: 'graph-board');
  double _zoomAtGestureStart = 1;

  GraphViewState get state => _state;

  @override
  void initState() {
    super.initState();
    _cardFocus.value = GraphCardFocus(
      selectedNodeId: _state.selectedNodeId,
      highlightedNodeIds: _state.highlightedNodeIds,
    );
  }

  @override
  void dispose() {
    _boardFocus.dispose();
    _cardFocus.dispose();
    super.dispose();
  }

  void update(GraphViewState next) {
    if (next == _state) return;
    setState(() => _state = next);
    // Selection and highlighting live outside the view state so only the cards
    // that show them rebuild.
    final focus = GraphCardFocus(
      selectedNodeId: next.selectedNodeId,
      highlightedNodeIds: next.highlightedNodeIds,
    );
    if (focus != _cardFocus.value) _cardFocus.value = focus;
    widget.onStateChanged?.call(next);
  }

  void _selectNode(String nodeId) {
    final gateId = widget.value?.document.index.nodeById[nodeId]?.gateId;
    // Selecting any anchor speaks about the one shared gate: the selection keeps
    // the anchor for spatial context and the gate identity for the count.
    update(
      _state.copyWith(
        selectedNodeId: nodeId,
        selectedGateId: gateId,
        showDetailPanel: true,
      ),
    );
  }

  void _clearSelection() => update(
    _state.copyWith(
      clearSelection: true,
      clearGate: true,
      clearRoleFilter: false,
    ),
  );

  List<String> _drawnNodeIds() {
    final value = widget.value;
    if (value == null) return const <String>[];
    final index = value.document.index;
    return <String>[
      for (final id in value.layout.visibleNodeIds)
        if (_state.draws(index.nodeById[id]!, value.statusById[id], index)) id,
    ];
  }

  void _moveSelection(int delta) {
    final drawn = _drawnNodeIds();
    if (drawn.isEmpty) return;
    final current = _state.selectedNodeId;
    final position = current == null ? -1 : drawn.indexOf(current);
    final next = position < 0
        ? (delta > 0 ? 0 : drawn.length - 1)
        : (position + delta).clamp(0, drawn.length - 1);
    _selectNode(drawn[next]);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowRight:
        _moveSelection(1);
      case LogicalKeyboardKey.arrowLeft:
        _moveSelection(-1);
      case LogicalKeyboardKey.arrowDown:
        _moveSelection(1);
      case LogicalKeyboardKey.arrowUp:
        _moveSelection(-1);
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.space:
        update(_state.copyWith(showDetailPanel: !_state.showDetailPanel));
      case LogicalKeyboardKey.escape:
        _clearSelection();
      case LogicalKeyboardKey.equal:
      case LogicalKeyboardKey.add:
        _zoomBy(0.2);
      case LogicalKeyboardKey.minus:
        _zoomBy(-0.2);
      case LogicalKeyboardKey.digit0:
        _resetView();
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  void _zoomBy(double delta) =>
      update(_state.copyWith(zoom: _state.zoom + delta));

  void _resetView() => update(_state.copyWith(zoom: 1, panX: 0, panY: 0));

  void _dispatch(GraphActionRequest request) {
    final handler = widget.onAction;
    if (handler == null) return;
    unawaited(Future<void>.sync(() => handler(request)));
  }

  @override
  Widget build(BuildContext context) {
    final available = widget.value;
    final reason = widget.unavailableReason;
    if (available == null) {
      return _Unavailable(
        reason:
            reason ?? (widget.pendingActions.isEmpty ? 'loading' : 'waiting'),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < widget.narrowBreakpoint;
        // A host may place the view in an unbounded column; the board still
        // needs a finite area to pan and scroll in.
        final hosted =
            !constraints.hasBoundedHeight || !constraints.hasBoundedWidth;
        final board = _Board(
          value: available,
          state: _state,
          update: update,
          cardFocus: _cardFocus,
          onSelect: _selectNode,
          focusNode: _boardFocus,
          onKey: _onKey,
          onScaleStart: () => _zoomAtGestureStart = _state.zoom,
          onScale: (scale, delta) => update(
            _state.copyWith(
              zoom: _zoomAtGestureStart * scale,
              panX: _state.panX + delta.dx,
              panY: _state.panY + delta.dy,
            ),
          ),
          onReset: _resetView,
          onZoomIn: () => _zoomBy(0.2),
          onZoomOut: () => _zoomBy(-0.2),
        );
        final Widget content;
        {
          // A narrow surface gets a real header instead of buttons floating
          // over the board: the panel switches and the controls live in their
          // own rows, so nothing covers the lanes and nothing is clipped.
          content = Column(
            children: [
              _NarrowHeader(
                value: available,
                state: _state,
                update: update,
                onReset: _resetView,
                onZoomIn: () => _zoomBy(0.2),
                onZoomOut: () => _zoomBy(-0.2),
              ),
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(child: board),
                    if (_state.showProjectPanel)
                      _Callout(
                        alignment: Alignment.centerLeft,
                        key: const Key('project-collaboration-projects-panel'),
                        onClose: () =>
                            update(_state.copyWith(showProjectPanel: false)),
                        child: SizedBox(
                          width: 300,
                          child: ProjectRail(
                            value: available,
                            state: _state,
                            update: update,
                          ),
                        ),
                      ),
                    if (_state.showDetailPanel)
                      _Callout(
                        alignment: Alignment.centerRight,
                        key: const Key('project-collaboration-detail-panel'),
                        onClose: () =>
                            update(_state.copyWith(showDetailPanel: false)),
                        child: SizedBox(
                          width: narrow ? 340 : 380,
                          child: GraphInspectorPanel(
                            value: available,
                            state: _state,
                            update: update,
                            pendingActions: widget.pendingActions,
                            onAction: _dispatch,
                            onClose: () =>
                                update(_state.copyWith(showDetailPanel: false)),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          );
        }
        if (!hosted) return content;
        return SizedBox(
          width: constraints.hasBoundedWidth ? null : 900,
          height: constraints.hasBoundedHeight ? null : 640,
          child: content,
        );
      },
    );
  }
}

class _Unavailable extends StatelessWidget {
  const _Unavailable({required this.reason});

  final String reason;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final strings = GraphViewStrings.of(context);
    final message = strings.unavailable(reason);
    return Center(
      key: const Key('project-collaboration-unavailable'),
      child: Semantics(
        label: '${strings.unavailableTitle}. $message',
        child: Padding(
          padding: const EdgeInsets.all(graphSpaceLg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                strings.unavailableTitle,
                style: theme.textTheme.titleSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: graphSpaceSm),
              Text(
                message,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The collapsible project rail with complete counts.
class ProjectRail extends StatelessWidget {
  const ProjectRail({
    super.key,
    required this.value,
    required this.state,
    required this.update,
  });

  final GraphPreparedValue value;
  final GraphViewState state;
  final ValueChanged<GraphViewState> update;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final roles = <String>{
      for (final project in value.document.projects)
        for (final node in project.nodes) node.role,
    }.toList()..sort();
    final strings = GraphViewStrings.of(context);
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: graphSpaceSm),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            graphSpaceMd,
            graphSpaceXs,
            graphSpaceMd,
            graphSpaceSm,
          ),
          child: Text(strings.projectsTitle, style: theme.textTheme.titleSmall),
        ),
        for (final project in value.document.projects)
          _ProjectRailEntry(
            project: project,
            summary: value.projectSummaries[project.id],
            collapsed: state.collapsedProjectIds.contains(project.id),
            onToggle: () {
              final collapsed = Set<String>.of(state.collapsedProjectIds);
              collapsed.contains(project.id)
                  ? collapsed.remove(project.id)
                  : collapsed.add(project.id);
              update(state.copyWith(collapsedProjectIds: collapsed));
            },
          ),
        const Divider(),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            graphSpaceMd,
            graphSpaceMd,
            graphSpaceMd,
            graphSpaceSm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                strings.roleFilterLabel,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  ChoiceChip(
                    key: const Key('project-collaboration-role-all'),
                    label: Text(strings.allRoles),
                    selected: state.roleFilter == null,
                    onSelected: (_) =>
                        update(state.copyWith(clearRoleFilter: true)),
                  ),
                  for (final role in roles)
                    ChoiceChip(
                      key: Key('project-collaboration-role-$role'),
                      label: Text(strings.roleName(role)),
                      selected: state.roleFilter == role,
                      onSelected: (_) =>
                          update(state.copyWith(roleFilter: role)),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ProjectRailEntry extends StatelessWidget {
  const _ProjectRailEntry({
    required this.project,
    required this.summary,
    required this.collapsed,
    required this.onToggle,
  });

  final GraphProject project;
  final GraphProjectSummary? summary;
  final bool collapsed;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final strings = GraphViewStrings.of(context);
    return InkWell(
      key: Key('project-collaboration-project-${project.id}'),
      onTap: onToggle,
      borderRadius: BorderRadius.circular(graphControlRadius),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: graphSpaceMd,
          vertical: graphSpaceSm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  collapsed
                      ? Icons.keyboard_arrow_right
                      : Icons.keyboard_arrow_down,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: graphSpaceSm),
                Expanded(
                  child: Text(
                    project.title,
                    style: theme.textTheme.bodyMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            if (summary != null)
              Padding(
                padding: const EdgeInsets.only(left: 26, top: graphSpaceXs),
                child: Text(
                  _countsLine(strings, summary!),
                  key: Key('project-collaboration-summary-${project.id}'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One compact counts line: totals first, then the states that need attention.
String _countsLine(GraphViewStrings strings, GraphProjectSummary summary) {
  final parts = <String>[
    '${summary.total} ${strings.units}',
    '${summary.ready} ${strings.ready}',
    '${summary.running} ${strings.running}',
    '${summary.accepted} ${strings.accepted}',
    if (summary.blocked > 0) '${summary.blocked} ${strings.blocked}',
    if (summary.stale > 0) '${summary.stale} ${strings.stale}',
  ];
  return parts.join(' · ');
}

/// The narrow surface header: panel switches on one row, the controls on the
/// next, so every primary control stays visible and reachable.
class _NarrowHeader extends StatelessWidget {
  const _NarrowHeader({
    required this.value,
    required this.state,
    required this.update,
    required this.onReset,
    required this.onZoomIn,
    required this.onZoomOut,
  });

  final GraphPreparedValue value;
  final GraphViewState state;
  final ValueChanged<GraphViewState> update;
  final VoidCallback onReset;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;

  @override
  Widget build(BuildContext context) {
    final strings = GraphViewStrings.of(context);
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(bottom: BorderSide(color: theme.colorScheme.outline)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _BoardToolbar(
            value: value,
            state: state,
            update: update,
            onReset: onReset,
            onZoomIn: onZoomIn,
            onZoomOut: onZoomOut,
            leading: <Widget>[
              _PanelButton(
                key: const Key('project-collaboration-open-projects'),
                label: strings.projectsTitle,
                icon: Icons.account_tree_outlined,
                onPressed: () => update(state.copyWith(showProjectPanel: true)),
              ),
              const SizedBox(width: graphSpaceSm),
              _PanelButton(
                key: const Key('project-collaboration-open-detail'),
                label: strings.detailsTitle,
                icon: Icons.article_outlined,
                onPressed: () => update(state.copyWith(showDetailPanel: true)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PanelButton extends StatelessWidget {
  const _PanelButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => FilledButton.tonalIcon(
    onPressed: onPressed,
    icon: Icon(icon, size: 18),
    label: Text(label),
  );
}

class _Callout extends StatelessWidget {
  const _Callout({
    super.key,
    required this.alignment,
    required this.child,
    required this.onClose,
  });

  final Alignment alignment;
  final Widget child;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 0,
      bottom: 0,
      left: alignment == Alignment.centerLeft ? 0 : null,
      right: alignment == Alignment.centerRight ? 0 : null,
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (alignment == Alignment.centerRight)
              IconButton(
                key: const Key('project-collaboration-close-detail'),
                onPressed: onClose,
                icon: const Icon(Icons.chevron_right),
                tooltip: 'Close details',
              ),
            child,
            if (alignment == Alignment.centerLeft)
              IconButton(
                key: const Key('project-collaboration-close-projects'),
                onPressed: onClose,
                icon: const Icon(Icons.chevron_left),
                tooltip: 'Close projects',
              ),
          ],
        ),
      ),
    );
  }
}

class _Board extends StatelessWidget {
  const _Board({
    required this.value,
    required this.state,
    required this.update,
    required this.cardFocus,
    required this.onSelect,
    required this.focusNode,
    required this.onKey,
    required this.onScaleStart,
    required this.onScale,
    required this.onReset,
    required this.onZoomIn,
    required this.onZoomOut,
  });

  final GraphPreparedValue value;
  final GraphViewState state;
  final ValueChanged<GraphViewState> update;
  final ValueListenable<GraphCardFocus> cardFocus;
  final ValueChanged<String> onSelect;
  final FocusNode focusNode;
  final KeyEventResult Function(FocusNode, KeyEvent) onKey;
  final VoidCallback onScaleStart;
  final void Function(double scale, Offset delta) onScale;
  final VoidCallback onReset;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: Focus(
            focusNode: focusNode,
            autofocus: true,
            onKeyEvent: onKey,
            child: Listener(
              onPointerDown: (_) => focusNode.requestFocus(),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onScaleStart: (_) => onScaleStart(),
                onScaleUpdate: (details) =>
                    onScale(details.scale, details.focalPointDelta),
                child: ClipRect(
                  child: Stack(
                    key: const Key('project-collaboration-graph'),
                    children: [
                      Transform.translate(
                        offset: Offset(state.panX, state.panY),
                        child: Transform.scale(
                          scale: state.zoom,
                          alignment: Alignment.topLeft,
                          child: state.showList
                              ? GraphCompactList(
                                  value: value,
                                  state: state,
                                  onSelect: onSelect,
                                )
                              : MemoizedBoardRows(
                                  value: value,
                                  state: state,
                                  update: update,
                                  onSelect: onSelect,
                                  focus: cardFocus,
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _BoardToolbar extends StatelessWidget {
  const _BoardToolbar({
    required this.value,
    required this.state,
    required this.update,
    required this.onReset,
    required this.onZoomIn,
    required this.onZoomOut,
    this.leading = const <Widget>[],
  });

  final GraphPreparedValue value;
  final GraphViewState state;
  final ValueChanged<GraphViewState> update;
  final VoidCallback onReset;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;

  /// Controls that precede the filters, used by the narrow header.
  final List<Widget> leading;

  @override
  Widget build(BuildContext context) {
    final strings = GraphViewStrings.of(context);
    return Padding(
      padding: const EdgeInsets.all(graphSpaceSm),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 4,
        runSpacing: 4,
        children: [
          ...leading,
          if (leading.isNotEmpty) const SizedBox(width: graphSpaceMd),
          SegmentedButton<GraphStatusFilter>(
            key: const Key('project-collaboration-filter'),
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: <ButtonSegment<GraphStatusFilter>>[
              ButtonSegment<GraphStatusFilter>(
                value: GraphStatusFilter.all,
                label: Text(
                  strings.filterAll,
                  key: const Key('project-collaboration-filter-all'),
                ),
              ),
              ButtonSegment<GraphStatusFilter>(
                value: GraphStatusFilter.frontier,
                label: Text(
                  strings.filterFrontier,
                  key: const Key('project-collaboration-filter-frontier'),
                ),
              ),
              ButtonSegment<GraphStatusFilter>(
                value: GraphStatusFilter.anomalies,
                label: Text(
                  strings.filterAnomalies,
                  key: const Key('project-collaboration-filter-anomalies'),
                ),
              ),
            ],
            selected: <GraphStatusFilter>{state.filter},
            onSelectionChanged: (selection) =>
                update(state.copyWith(filter: selection.first)),
          ),
          const SizedBox(width: graphSpaceMd),
          IconButton(
            key: const Key('project-collaboration-inspector-toggle'),
            onPressed: () =>
                update(state.copyWith(showInspector: !state.showInspector)),
            icon: const Icon(Icons.rule, size: 20),
            visualDensity: VisualDensity.compact,
            tooltip: strings.inspectorTooltip,
          ),
          IconButton(
            key: const Key('project-collaboration-list-toggle'),
            onPressed: () => update(state.copyWith(showList: !state.showList)),
            icon: Icon(
              state.showList ? Icons.account_tree : Icons.list_alt,
              size: 20,
            ),
            visualDensity: VisualDensity.compact,
            tooltip: state.showList
                ? strings.swimlanesTooltip
                : strings.listTooltip,
          ),
          const SizedBox(width: graphSpaceSm),
          IconButton(
            key: const Key('project-collaboration-zoom-out'),
            onPressed: onZoomOut,
            icon: const Icon(Icons.zoom_out, size: 20),
            visualDensity: VisualDensity.compact,
            tooltip: strings.zoomOut,
          ),
          Semantics(
            label: strings.zoomPercent((state.zoom * 100).round()),
            child: Text(
              '${(state.zoom * 100).round()}%',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          IconButton(
            key: const Key('project-collaboration-zoom-in'),
            onPressed: onZoomIn,
            icon: const Icon(Icons.zoom_in, size: 20),
            visualDensity: VisualDensity.compact,
            tooltip: strings.zoomIn,
          ),
          IconButton(
            key: const Key('project-collaboration-zoom-reset'),
            onPressed: onReset,
            icon: const Icon(Icons.center_focus_strong_outlined, size: 20),
            visualDensity: VisualDensity.compact,
            tooltip: strings.resetView,
          ),
        ],
      ),
    );
  }
}

/// The virtualized board: project headers and lane rows in one lazy list.
///
/// Only the rows inside the viewport are built, and only the cards inside a
/// lane's viewport are built, so a 1000-unit projection paints what is on
/// screen instead of the whole window. Every count still comes from the
/// prepared value: virtualization limits the drawing, never the totals.
class BoardRows extends StatelessWidget {
  const BoardRows({
    super.key,
    required this.value,
    required this.state,
    required this.update,
    required this.onSelect,
    required this.focus,
  });

  final GraphPreparedValue value;
  final GraphViewState state;
  final ValueChanged<GraphViewState> update;
  final ValueChanged<String> onSelect;
  final ValueListenable<GraphCardFocus> focus;

  @override
  Widget build(BuildContext context) {
    final rows = boardRows(value, state);
    final projects = rows.whereType<BoardProjectRow>().toList(growable: false);
    final noteCount =
        value.layout.visibleNodeIds.length < value.document.nodeCount ? 1 : 0;
    return ListView.builder(
      key: const Key('project-collaboration-board-rows'),
      padding: const EdgeInsets.all(12),
      itemCount: projects.length + noteCount,
      itemBuilder: (context, index) {
        if (index >= projects.length) {
          final strings = GraphViewStrings.of(context);
          return Padding(
            padding: const EdgeInsets.only(top: graphSpaceSm),
            child: Text(
              GraphViewStrings.fill(strings.windowNote, <String, String>{
                'shown': '${value.layout.visibleNodeIds.length}',
                'total': '${value.document.nodeCount}',
              }),
              key: const Key('project-collaboration-window-note'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          );
        }
        final project = projects[index].project;
        final lanes = rows
            .whereType<BoardLaneRow>()
            .where((row) => row.project.id == project.id)
            .toList(growable: false);
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1040),
            child: Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ProjectHeaderRow(
                    project: project,
                    summary: value.projectSummaries[project.id],
                  ),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final columns = constraints.maxWidth >= 700 ? 2 : 1;
                      final width =
                          (constraints.maxWidth - (columns - 1) * 16) / columns;
                      return Wrap(
                        spacing: 16,
                        runSpacing: 8,
                        children: [
                          for (final row in lanes)
                            SizedBox(
                              width: width,
                              child: LaneSwimlane(
                                key: Key(
                                  'project-collaboration-lane-${row.lane.id}',
                                ),
                                lane: row.lane,
                                project: row.project,
                                value: value,
                                state: state,
                                update: update,
                                onSelect: onSelect,
                                nodeIds: row.nodeIds,
                                focus: focus,
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// One row of the virtualized board.
sealed class BoardRow {
  const BoardRow();
}

/// A project header row.
final class BoardProjectRow extends BoardRow {
  const BoardProjectRow(this.project);

  final GraphProject project;
}

/// One lane row with the units the window and the filters put in it.
final class BoardLaneRow extends BoardRow {
  const BoardLaneRow({
    required this.project,
    required this.lane,
    required this.nodeIds,
  });

  final GraphProject project;
  final GraphLane lane;
  final List<String> nodeIds;
}

/// Flattens the prepared value and the interface state into board rows.
///
/// The order is stable: project declaration order, lane order, then the causal
/// order of the units inside the lane.
List<BoardRow> boardRows(GraphPreparedValue value, GraphViewState state) {
  final index = value.document.index;
  final rows = <BoardRow>[];
  for (final project in value.document.projects) {
    if (state.collapsedProjectIds.contains(project.id)) continue;
    rows.add(BoardProjectRow(project));
    final lanes = List<GraphLane>.of(project.lanes)
      ..sort((left, right) {
        final order = state.laneOrder;
        final leftIndex = order.isEmpty ? left.order : order.indexOf(left.id);
        final rightIndex = order.isEmpty
            ? right.order
            : order.indexOf(right.id);
        return leftIndex.compareTo(rightIndex);
      });
    for (final lane in lanes) {
      if (state.collapsedLaneIds.contains(lane.id)) continue;
      final nodeIds =
          <String>[
            for (final id in value.layout.visibleNodeIds)
              if (index.laneOfNode[id] == lane.id &&
                  state.draws(index.nodeById[id]!, value.statusById[id], index))
                id,
          ]..sort((left, right) {
            final byLayer = value.layout.layerOf[left]!.compareTo(
              value.layout.layerOf[right]!,
            );
            if (byLayer != 0) return byLayer;
            return value.layout.positionInLayer[left]!.compareTo(
              value.layout.positionInLayer[right]!,
            );
          });
      rows.add(BoardLaneRow(project: project, lane: lane, nodeIds: nodeIds));
    }
  }
  return rows;
}

/// One project header inside the board list.
class ProjectHeaderRow extends StatelessWidget {
  const ProjectHeaderRow({
    super.key,
    required this.project,
    required this.summary,
  });

  final GraphProject project;
  final GraphProjectSummary? summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final strings = GraphViewStrings.of(context);
    return Padding(
      key: Key('project-collaboration-board-${project.id}'),
      padding: const EdgeInsets.only(top: 12, bottom: graphSpaceXs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(project.title, style: theme.textTheme.titleMedium),
          if (summary != null) ...[
            const SizedBox(height: graphSpaceXs),
            Text(
              _countsLine(strings, summary!),
              key: Key('project-collaboration-canvas-summary-${project.id}'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One lane: header, drag handle and the horizontally virtualized unit row.
class LaneSwimlane extends StatelessWidget {
  const LaneSwimlane({
    super.key,
    required this.lane,
    required this.project,
    required this.value,
    required this.state,
    required this.update,
    required this.onSelect,
    required this.nodeIds,
    required this.focus,
  });

  final GraphLane lane;
  final GraphProject project;
  final GraphPreparedValue value;
  final GraphViewState state;
  final ValueChanged<GraphViewState> update;
  final ValueChanged<String> onSelect;
  final List<String> nodeIds;
  final ValueListenable<GraphCardFocus> focus;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final strings = GraphViewStrings.of(context);
    final summary = value.laneSummaries[lane.id];
    final collapsed = state.collapsedLaneIds.contains(lane.id);
    return DragTarget<String>(
      onAcceptWithDetails: (details) {
        final order = List<String>.of(
          state.laneOrder.isEmpty
              ? (List<GraphLane>.of(
                      project.lanes,
                    )..sort((left, right) => left.order.compareTo(right.order)))
                    .map((entry) => entry.id)
              : state.laneOrder,
        );
        order.remove(details.data);
        final position = order.indexOf(lane.id);
        order.insert(position < 0 ? order.length : position, details.data);
        // Dragging a lane is layout only: no action is dispatched and no
        // execution state is touched.
        update(state.copyWith(laneOrder: order));
      },
      builder: (context, candidate, rejected) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LongPressDraggable<String>(
            data: lane.id,
            feedback: Material(
              color: theme.colorScheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: Text(lane.title),
              ),
            ),
            child: InkWell(
              key: Key('project-collaboration-lane-header-${lane.id}'),
              onTap: () {
                final collapsedLanes = Set<String>.of(state.collapsedLaneIds);
                collapsedLanes.contains(lane.id)
                    ? collapsedLanes.remove(lane.id)
                    : collapsedLanes.add(lane.id);
                update(state.copyWith(collapsedLaneIds: collapsedLanes));
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: graphSpaceSm,
                  vertical: graphSpaceXs,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(graphControlRadius),
                  // A lane that is about to receive a dragged lane is shown by
                  // a surface change, not by an added outline.
                  color: candidate.isNotEmpty
                      ? theme.colorScheme.secondaryContainer
                      : Colors.transparent,
                ),
                child: Row(
                  children: [
                    Icon(
                      collapsed ? Icons.chevron_right : Icons.expand_more,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: graphSpaceXs),
                    Text(lane.title, style: theme.textTheme.labelLarge),
                    const SizedBox(width: graphSpaceSm),
                    if (summary != null)
                      Flexible(
                        child: Text(
                          '${summary.total} ${strings.units} · '
                          '${summary.ready} ${strings.ready}'
                          '${summary.blocked == 0 ? '' : ' · ${summary.blocked} ${strings.blocked}'}',
                          key: Key(
                            'project-collaboration-lane-summary-${lane.id}',
                          ),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (!collapsed)
            if (nodeIds.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: graphSpaceSm,
                  vertical: graphSpaceSm,
                ),
                child: Text(
                  state.filter == GraphStatusFilter.all
                      ? strings.emptyWindow
                      : strings.emptyFiltered,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              LaneRow(
                nodeIds: nodeIds,
                value: value,
                state: state,
                onSelect: onSelect,
                focus: focus,
              ),
          const Divider(),
        ],
      ),
    );
  }
}

/// One lane's units, built lazily by the horizontal viewport.
class LaneRow extends StatelessWidget {
  const LaneRow({
    super.key,
    required this.nodeIds,
    required this.value,
    required this.state,
    required this.onSelect,
    required this.focus,
  });

  final List<String> nodeIds;
  final GraphPreparedValue value;
  final GraphViewState state;
  final ValueChanged<String> onSelect;
  final ValueListenable<GraphCardFocus> focus;

  /// Text scaling grows the card instead of clipping it. The base leaves room
  /// for a title, three status chips and two short lines at the control sizes.
  static double cardHeight(BuildContext context) {
    final scaled = MediaQuery.textScalerOf(context).scale(1);
    final text = Theme.of(context).textTheme;
    final titleLine =
        (text.bodyMedium?.fontSize ?? 13) * (text.bodyMedium?.height ?? 1.45);
    final smallLine =
        (text.labelSmall?.fontSize ?? 11) * (text.labelSmall?.height ?? 1.4);
    return (24 + titleLine * scaled + smallLine * scaled * 5).clamp(108, 280);
  }

  @override
  Widget build(BuildContext context) {
    final height = cardHeight(context);
    final laneUnits = nodeIds.toSet();
    return SizedBox(
      height: height + 8,
      child: ListView.builder(
        key: Key('project-collaboration-lane-row-${nodeIds.first}'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        itemCount: nodeIds.length,
        // A card draws its own links into the gap, so an edge never needs the
        // whole document to be walked while painting.
        itemBuilder: (context, index) {
          final id = nodeIds[index];
          return Padding(
            padding: const EdgeInsets.only(right: LaneCard.cellGap),
            child: LaneCard(
              nodeId: id,
              value: value,
              state: state,
              onSelect: onSelect,
              height: height,
              laneUnits: laneUnits,
              focus: focus,
            ),
          );
        },
      ),
    );
  }
}

/// The per-card interface facts that change on selection and highlighting.
///
/// Keeping them in one small listenable lets a selection repaint the cards
/// without rebuilding the board rows, which is what made selecting a unit cost
/// a whole-board frame.
final class GraphCardFocus {
  const GraphCardFocus({
    this.selectedNodeId,
    this.highlightedNodeIds = const <String>{},
  });

  static const GraphCardFocus empty = GraphCardFocus();

  final String? selectedNodeId;
  final Set<String> highlightedNodeIds;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GraphCardFocus &&
          other.selectedNodeId == selectedNodeId &&
          other.highlightedNodeIds.length == highlightedNodeIds.length &&
          other.highlightedNodeIds.every(highlightedNodeIds.contains);

  @override
  int get hashCode =>
      Object.hash(selectedNodeId, Object.hashAllUnordered(highlightedNodeIds));
}

/// Memoizes the board rows so an interface change the rows do not read — a
/// selection, a highlight, pan or zoom — costs no row rebuild at all.
class MemoizedBoardRows extends StatefulWidget {
  const MemoizedBoardRows({
    super.key,
    required this.value,
    required this.state,
    required this.update,
    required this.onSelect,
    required this.focus,
  });

  final GraphPreparedValue value;
  final GraphViewState state;
  final ValueChanged<GraphViewState> update;
  final ValueChanged<String> onSelect;
  final ValueListenable<GraphCardFocus> focus;

  @override
  State<MemoizedBoardRows> createState() => _MemoizedBoardRowsState();
}

class _MemoizedBoardRowsState extends State<MemoizedBoardRows> {
  Widget? _cached;
  Object? _key;

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final key = (
      Theme.of(context),
      GraphViewStrings.of(context),
      widget.value,
      state.collapsedProjectIds,
      state.collapsedLaneIds,
      state.laneOrder,
      state.filter,
      state.roleFilter,
      state.showList,
    );
    if (_cached == null || _key != key) {
      _cached = BoardRows(
        value: widget.value,
        state: state,
        update: widget.update,
        onSelect: widget.onSelect,
        focus: widget.focus,
      );
      _key = key;
    }
    return _cached!;
  }
}

/// One card cell with its outgoing causal links inside the same lane.
class LaneCard extends StatelessWidget {
  const LaneCard({
    super.key,
    required this.nodeId,
    required this.value,
    required this.state,
    required this.onSelect,
    required this.height,
    required this.laneUnits,
    required this.focus,
  });

  final String nodeId;
  final GraphPreparedValue value;
  final GraphViewState state;
  final ValueChanged<String> onSelect;
  final double height;
  final Set<String> laneUnits;
  final ValueListenable<GraphCardFocus> focus;

  static const double cardWidth = 248;
  static const double cellGap = 12;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final index = value.document.index;
    // Only this unit's own outgoing edges are consulted, and only those that
    // stay inside the lane are drawn here; the rest are named in the inspector.
    final links = <({int offset, GraphEdgeKind kind})>[];
    for (final edge in index.edgesBySource[nodeId] ?? const <GraphEdge>[]) {
      final target = nodeIds.indexOf(edge.to);
      if (target < 0) continue;
      links.add((offset: target, kind: edge.kind));
    }
    links.sort((left, right) => left.offset.compareTo(right.offset));
    return SizedBox(
      width: cardWidth + cellGap,
      height: height,
      child: Row(
        children: [
          NodeCard(
            nodeId: nodeId,
            value: value,
            state: state,
            onSelect: onSelect,
            height: height,
            focus: focus,
          ),
          Expanded(
            child: CustomPaint(
              painter: LaneLinkPainter(
                links: <int>[for (final link in links) link.offset],
                color: theme.colorScheme.outline,
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<String> get nodeIds => laneUnits.toList(growable: false);
}

/// Draws this card's outgoing causal links inside its own cell.
class LaneLinkPainter extends CustomPainter {
  const LaneLinkPainter({required this.links, required this.color});

  final List<int> links;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (links.isEmpty) return;
    final paint = Paint()
      ..color = color.withValues(alpha: 0.7)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    final path = Path()
      ..moveTo(0, size.height / 2)
      ..lineTo(size.width, size.height / 2);
    canvas.drawPath(path, paint);
    canvas.drawCircle(
      Offset(size.width, size.height / 2),
      2,
      paint..style = PaintingStyle.fill,
    );
    paint.style = PaintingStyle.stroke;
  }

  @override
  bool shouldRepaint(LaneLinkPainter oldDelegate) =>
      oldDelegate.links.length != links.length || oldDelegate.color != color;
}

/// One node card: title, the three status dimensions and the main gap.
class NodeCard extends StatelessWidget {
  const NodeCard({
    super.key,
    required this.nodeId,
    required this.value,
    required this.state,
    required this.onSelect,
    this.height = 108,
    this.focus,
  });

  final String nodeId;
  final GraphPreparedValue value;
  final GraphViewState state;
  final ValueChanged<String> onSelect;
  final double height;

  /// Selection and highlighting, kept outside the view state so a selection
  /// repaints only the cards instead of the whole board.
  final ValueListenable<GraphCardFocus>? focus;

  @override
  Widget build(BuildContext context) {
    final focusListenable = focus;
    if (focusListenable != null) {
      return ValueListenableBuilder<GraphCardFocus>(
        valueListenable: focusListenable,
        builder: (context, focusValue, _) => _card(
          context,
          selected: focusValue.selectedNodeId == nodeId,
          highlighted: focusValue.highlightedNodeIds.contains(nodeId),
        ),
      );
    }
    return _card(
      context,
      selected: state.selectedNodeId == nodeId,
      highlighted: state.highlightedNodeIds.contains(nodeId),
    );
  }

  Widget _card(
    BuildContext context, {
    required bool selected,
    required bool highlighted,
  }) {
    final theme = Theme.of(context);
    final strings = GraphViewStrings.of(context);
    final node = value.document.index.nodeById[nodeId]!;
    final status = value.statusById[nodeId];
    final gateId = node.gateId;
    final representative = gateId == null
        ? null
        : value.gateRepresentative[gateId];
    final sharedAnchor = gateId != null && representative != nodeId;
    final blocker = status?.mainBlocker;
    return Semantics(
      label: _semanticLabel(strings, node, status, sharedAnchor),
      button: true,
      selected: selected,
      child: InkWell(
        key: Key('project-collaboration-node-$nodeId'),
        onTap: () => onSelect(nodeId),
        borderRadius: BorderRadius.circular(graphContentRadius),
        child: Container(
          width: LaneCard.cardWidth,
          height: height,
          padding: const EdgeInsets.all(graphSpaceSm),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(graphContentRadius),
            // A flat content surface; selection is a filled interaction
            // surface with a focus ring, and a blocked unit carries a bar so
            // the state never depends on colour alone.
            color: selected
                ? theme.colorScheme.secondaryContainer
                : theme.colorScheme.surfaceContainerHighest,
            border: highlighted
                ? Border(
                    left: BorderSide(
                      width: 3,
                      color: theme.colorScheme.tertiary,
                    ),
                  )
                : null,
          ),
          foregroundDecoration: selected
              ? BoxDecoration(
                  borderRadius: BorderRadius.circular(graphContentRadius),
                  border: Border.all(
                    width: 2,
                    color: theme.colorScheme.secondary,
                  ),
                )
              : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      node.title,
                      style: theme.textTheme.bodyMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    'L${value.layout.layerOf[nodeId] ?? 0}',
                    style: theme.textTheme.labelSmall,
                  ),
                ],
              ),
              const SizedBox(height: graphSpaceXs),
              Wrap(
                spacing: graphSpaceXs,
                runSpacing: graphSpaceXs,
                children: [
                  StatusBadge(
                    key: Key('project-collaboration-execution-$nodeId'),
                    label: strings.execution(status?.execution),
                    tone: _executionTone(theme, status),
                  ),
                  StatusBadge(
                    key: Key('project-collaboration-acceptance-$nodeId'),
                    label: strings.acceptance(status?.acceptance),
                    tone: theme.colorScheme.onSurfaceVariant,
                  ),
                  StatusBadge(
                    key: Key('project-collaboration-observation-$nodeId'),
                    label: strings.observation(status?.observation),
                    tone: status?.observation == GraphObservationState.stale
                        ? theme.colorScheme.error
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              if (gateId != null)
                Text(
                  sharedAnchor
                      ? strings.gateShared
                      : GraphViewStrings.fill(strings.gateRuns, <
                          String,
                          String
                        >{
                          'runs':
                              '${value.document.index.gateById[gateId]?.runCount ?? 0}',
                        }),
                  key: Key('project-collaboration-gate-badge-$nodeId'),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.tertiary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              if (blocker != null)
                Text(
                  GraphViewStrings.fill(strings.cannotStart, <String, String>{
                    'reason': strings.blocker(blocker.code),
                  }),
                  key: Key('project-collaboration-gap-$nodeId'),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                )
              else if (status?.startable == true)
                Text(
                  strings.startableNow,
                  key: Key('project-collaboration-gap-$nodeId'),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.secondary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                )
              else if (status?.ready == true)
                Text(
                  strings.readyNotStartable,
                  key: Key('project-collaboration-gap-$nodeId'),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
      ),
    );
  }

  static Color _executionTone(ThemeData theme, GraphStatusEntry? status) =>
      switch (status?.execution) {
        GraphExecutionState.failed => theme.colorScheme.error,
        GraphExecutionState.running => theme.colorScheme.secondary,
        GraphExecutionState.succeeded => theme.colorScheme.tertiary,
        _ => theme.colorScheme.onSurface,
      };

  static String _semanticLabel(
    GraphViewStrings strings,
    GraphNode node,
    GraphStatusEntry? status,
    bool sharedAnchor,
  ) {
    final parts = <String>[
      node.title,
      '${strings.factExecution}: ${strings.execution(status?.execution)}',
      '${strings.factAcceptance}: ${strings.acceptance(status?.acceptance)}',
      '${strings.factObservation}: ${strings.observation(status?.observation)}',
      if (status?.ready == true) strings.ready,
      if (status?.startable == true) strings.startableNow,
      if (status != null && !status.startable && status.blockers.isNotEmpty)
        GraphViewStrings.fill(strings.cannotStart, <String, String>{
          'reason': status.blockers
              .map((blocker) => strings.blocker(blocker.code))
              .join(', '),
        }),
      if (sharedAnchor) strings.gateShared,
      if (node.gateId != null && !sharedAnchor) strings.sharedGate,
    ];
    return parts.join('; ');
  }
}

/// A compact status chip. The label always carries the meaning; colour never
/// does on its own.
class StatusBadge extends StatelessWidget {
  const StatusBadge({super.key, required this.label, required this.tone});

  final String label;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final background = colors.surface;
    double contrast(Color foreground) {
      final a = foreground.computeLuminance();
      final b = background.computeLuminance();
      return ((a > b ? a : b) + 0.05) / ((a < b ? a : b) + 0.05);
    }

    final foreground = contrast(tone) >= 4.5 ? tone : colors.onSurface;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(graphWellRadius),
        color: background,
        border: Border.all(color: Theme.of(context).colorScheme.outline),
      ),
      child: Text(
        label,
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: foreground),
      ),
    );
  }
}
