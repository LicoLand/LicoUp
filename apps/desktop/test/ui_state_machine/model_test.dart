import 'package:flutter_test/flutter_test.dart';

import 'model.dart';

void main() {
  test(
    'recorded seeds replay the same choices and explore different paths',
    () {
      List<int> choices(int seed) {
        final random = UiRandom(seed);
        return List.generate(100, (_) => random.choose(7));
      }

      expect(choices(42), choices(42));
      expect(choices(42), isNot(choices(915)));
      expect(choices(42).toSet(), hasLength(7));
    },
  );

  test(
    'every declared click is reachable without resetting the current state',
    () {
      final model = UiInteractionModel.load();
      for (final machine in model.machines) {
        var state = machine.initial;
        final visited = <String>{};
        for (final edge in machine.coverageWalk()) {
          expect(
            edge.from,
            state,
            reason: 'The user must already be at the source of ${edge.id}',
          );
          expect(model.actions, contains(edge.action));
          visited.add(edge.id);
          state = edge.to;
        }
        expect(visited, machine.transitions.map((edge) => edge.id).toSet());
        expect(
          visited.length,
          machine.transitions.length,
          reason: 'Transition identities must be unique',
        );
      }
    },
  );
}
