import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/composition/dispose_all.dart';

void main() {
  test(
    'disposeAll attempts every cleanup before rethrowing first failure',
    () async {
      final calls = <String>[];
      final firstFailure = StateError('first');

      await expectLater(
        disposeAll([
          () {
            calls.add('first');
            throw firstFailure;
          },
          () async {
            calls.add('second');
            throw ArgumentError('second');
          },
          () => calls.add('third'),
        ]),
        throwsA(same(firstFailure)),
      );

      expect(calls, ['first', 'second', 'third']);
    },
  );
}
