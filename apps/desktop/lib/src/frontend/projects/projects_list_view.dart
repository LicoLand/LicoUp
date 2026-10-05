import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/projects/project_work_item_card.dart';
import 'package:licoup/src/frontend/shared/ui/lico_empty_state.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/projects/projects_view.dart';

/// The list view of one project's work items.
///
/// The view renders [ProjectsListViewInputs] and receives one way to change the
/// local order: [onReorder], which the surface wires to the local arrangement
/// alone. The row order is local; the declared result, the blocking reason and
/// the real dependents come from [ProjectsListViewInputs.facts], the identical
/// list the graph view reads.
final class ProjectsListView extends StatelessWidget {
  const ProjectsListView({
    super.key,
    required this.inputs,
    required this.selectedKey,
    required this.onSelect,
    required this.onReorder,
  });

  final ProjectsListViewInputs inputs;
  final String selectedKey;
  final ValueChanged<String> onSelect;
  final ValueChanged<Iterable<String>> onReorder;

  @override
  Widget build(BuildContext context) {
    final rows = inputs.rows;
    if (rows.isEmpty) {
      return const LicoEmptyState(
        icon: Icons.list_alt_outlined,
        title: 'No declared work',
        message:
            'This project holds no work item this client read. Declared work '
            'arrives only through a caller-converted plan document.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          'The order below is this client\'s own arrangement. Reordering never '
          'sends a command and never changes a work item.',
          style: TextStyle(color: context.licoColors.textMuted, fontSize: 11),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ListView.separated(
            key: const Key('projects-list'),
            itemCount: rows.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final row = rows[index];
              return Row(
                key: Key('project-list-row-${row.workItemId}'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SizedBox(
                    width: 28,
                    child: Text(
                      '${row.position + 1}',
                      style: TextStyle(
                        color: context.licoColors.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  Expanded(
                    child: ProjectWorkItemCard(
                      facts: row.facts,
                      selected: row.key == selectedKey,
                      onTap: () => onSelect(row.key),
                    ),
                  ),
                  Column(
                    children: <Widget>[
                      IconButton(
                        key: Key('project-list-up-${row.workItemId}'),
                        tooltip: 'Move up',
                        onPressed: index == 0
                            ? null
                            : () =>
                                  onReorder(_reordered(rows, index, index - 1)),
                        icon: const Icon(Icons.keyboard_arrow_up, size: 18),
                      ),
                      IconButton(
                        key: Key('project-list-down-${row.workItemId}'),
                        tooltip: 'Move down',
                        onPressed: index == rows.length - 1
                            ? null
                            : () =>
                                  onReorder(_reordered(rows, index, index + 1)),
                        icon: const Icon(Icons.keyboard_arrow_down, size: 18),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  /// The local order with the row at [from] placed at [to].
  static List<String> _reordered(
    List<ProjectListRowInputs> rows,
    int from,
    int to,
  ) {
    final keys = <String>[for (final row in rows) row.key];
    final moved = keys.removeAt(from);
    keys.insert(to, moved);
    return keys;
  }
}
