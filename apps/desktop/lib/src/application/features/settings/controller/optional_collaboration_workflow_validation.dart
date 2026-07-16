import 'package:flutter_client/src/contracts/optional_collaboration_models.dart';
import 'package:flutter_client/src/contracts/optional_collaboration_workflow_models.dart';

List<String>? validateOptionalCollaborationSelection(
  List<String> selectedIds,
  List<OptionalCollaborationWorkflowChoice> choices,
) {
  final allowed = choices.map((choice) => choice.id).toSet();
  final selected = selectedIds.map((id) => id.trim()).toList(growable: false)
    ..sort();
  if (selected.isEmpty ||
      selected.toSet().length != selected.length ||
      selected.any((id) => !allowed.contains(id))) {
    return null;
  }
  return List.unmodifiable(selected);
}

List<OptionalCollaborationAgentDestination>?
validateOptionalCollaborationAgentDestinations(
  List<OptionalCollaborationAgentDestination> input,
) {
  if (input.isEmpty || input.length > 32) return null;
  final destinations =
      input
          .map(
            (item) => OptionalCollaborationAgentDestination(
              agentId: item.agentId.trim(),
              installDestination: item.installDestination.trim(),
            ),
          )
          .toList(growable: false)
        ..sort((left, right) => left.agentId.compareTo(right.agentId));
  final agents = <String>{};
  final paths = <String>[];
  for (final destination in destinations) {
    if (!supportedOptionalCollaborationMcpAgentIds.contains(
          destination.agentId,
        ) ||
        !agents.add(destination.agentId) ||
        !looksLikeOptionalCollaborationAbsolutePath(
          destination.installDestination,
        )) {
      return null;
    }
    paths.add(destination.installDestination);
  }
  for (var left = 0; left < paths.length; left += 1) {
    for (var right = left + 1; right < paths.length; right += 1) {
      if (_pathsOverlap(paths[left], paths[right])) return null;
    }
  }
  return List.unmodifiable(destinations);
}

const supportedOptionalCollaborationMcpAgentIds = <String>{
  'copilot',
  'cursor',
  'hermes',
  'kimi-code',
  'openclaw',
};

bool looksLikeOptionalCollaborationAbsolutePath(String value) {
  if (value.isEmpty || value.length > 4096 || value != value.trim()) {
    return false;
  }
  final absolute =
      value.startsWith('/') ||
      value.startsWith(r'\\') ||
      RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value);
  return absolute &&
      !value
          .split(RegExp(r'[\\/]'))
          .any((segment) => segment == '.' || segment == '..');
}

bool _pathsOverlap(String left, String right) {
  final normalizedLeft = left
      .replaceAll('\\', '/')
      .replaceAll(RegExp(r'/+$'), '');
  final normalizedRight = right
      .replaceAll('\\', '/')
      .replaceAll(RegExp(r'/+$'), '');
  return normalizedLeft == normalizedRight ||
      normalizedLeft.startsWith('$normalizedRight/') ||
      normalizedRight.startsWith('$normalizedLeft/');
}
