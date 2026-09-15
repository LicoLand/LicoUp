import 'dart:collection';
import 'dart:convert';
import 'dart:io';

/// The product model contains only visible states and user actions. This file
/// deliberately has no Flutter, application, controller, or backend imports.
final class UiInteractionModel {
  UiInteractionModel(Map<String, dynamic> json)
    : actions = Map<String, dynamic>.from(json['actions'] as Map),
      machines = [
        for (final value in json['machines'] as List)
          UiMachine(Map<String, dynamic>.from(value as Map)),
      ];

  factory UiInteractionModel.load() {
    const encoded = String.fromEnvironment('LICO_UI_MODEL');
    if (encoded.isNotEmpty) {
      return UiInteractionModel(
        jsonDecode(utf8.decode(base64Decode(encoded))) as Map<String, dynamic>,
      );
    }
    var directory = Directory.current;
    while (true) {
      final file = File(
        '${directory.path}/docs/functionality/UI-INTERACTIONS.json',
      );
      if (file.existsSync()) {
        return UiInteractionModel(
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>,
        );
      }
      final parent = directory.parent;
      if (parent.path == directory.path) {
        throw StateError('Run from the repository or supply LICO_UI_MODEL.');
      }
      directory = parent;
    }
  }

  final Map<String, dynamic> actions;
  final List<UiMachine> machines;
  String actionLabel(String id) => (actions[id] as Map)['label'] as String;
}

final class UiMachine {
  UiMachine(Map<String, dynamic> json)
    : id = json['id'] as String,
      label = json['label'] as String,
      presentation = json['presentation'] as String,
      initial = json['initial'] as String,
      setup = List<String>.from(json['setup'] as List),
      populated = json['scenario'] == 'populated-conversations',
      observations = {
        for (final state in json['states'] as List)
          if ((state as Map)['view'] != null)
            state['id'] as String: Map<String, dynamic>.from(
              state['view'] as Map,
            ),
      },
      states = {
        for (final state in json['states'] as List)
          (state as Map)['id'] as String: state['label'] as String,
      },
      transitions = [
        for (final edge in json['transitions'] as List)
          UiTransition(Map<String, dynamic>.from(edge as Map)),
      ] {
    if (!states.containsKey(initial)) {
      throw FormatException('Missing initial state: $id/$initial');
    }
    if (states.length != (json['states'] as List).length) {
      throw FormatException('Duplicate state in $id');
    }
    final ids = <String>{};
    final choices = <String>{};
    for (final edge in transitions) {
      if (!ids.add(edge.id) || !choices.add('${edge.from}/${edge.action}')) {
        throw FormatException('Ambiguous transition: ${edge.id}');
      }
      if (!states.containsKey(edge.from) || !states.containsKey(edge.to)) {
        throw FormatException('Unknown visible state in ${edge.id}');
      }
      outgoing.putIfAbsent(edge.from, () => []).add(edge);
    }
  }

  final String id;
  final String label;
  final String presentation;
  final String initial;
  final List<String> setup;
  final bool populated;
  final Map<String, Map<String, dynamic>> observations;
  final Map<String, String> states;
  final List<UiTransition> transitions;
  final Map<String, List<UiTransition>> outgoing = {};

  /// Walk every declared edge, navigating by shortest user-action paths.
  /// No controller reset can hide a failure between transitions.
  List<UiTransition> coverageWalk() {
    final remaining = transitions.map((edge) => edge.id).toSet();
    final walk = <UiTransition>[];
    var current = initial;
    while (remaining.isNotEmpty) {
      final queue = ListQueue<String>()..add(current);
      final previous = <String, UiTransition?>{current: null};
      UiTransition? next;
      while (queue.isNotEmpty && next == null) {
        final state = queue.removeFirst();
        for (final edge in outgoing[state] ?? <UiTransition>[]) {
          if (remaining.contains(edge.id)) {
            next = edge;
            break;
          }
          if (!previous.containsKey(edge.to)) {
            previous[edge.to] = edge;
            queue.add(edge.to);
          }
        }
      }
      if (next == null) {
        throw StateError('$id has an unreachable transition from $current');
      }
      final path = <UiTransition>[];
      var cursor = next.from;
      while (cursor != current) {
        final edge = previous[cursor]!;
        path.add(edge);
        cursor = edge.from;
      }
      for (final edge in [...path.reversed, next]) {
        walk.add(edge);
        remaining.remove(edge.id);
        current = edge.to;
      }
    }
    return walk;
  }
}

final class UiTransition {
  UiTransition(Map<String, dynamic> json)
    : id = json['id'] as String,
      from = json['from_state'] as String,
      action = json['action'] as String,
      to = json['to_state'] as String;

  final String id;
  final String from;
  final String action;
  final String to;
}

/// Stable across Dart versions: record the seed and every chosen transition.
/// This is exploration randomness, never a security or product identifier.
final class UiRandom {
  UiRandom(int seed) : _value = seed & 0xffffffff;
  int _value;
  int choose(int length) {
    if (length <= 0) throw StateError('No visible actions to choose');
    _value = (1664525 * _value + 1013904223) & 0xffffffff;
    return _value % length;
  }
}
