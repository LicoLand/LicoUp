import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/state/application_signal.dart';
import 'package:licoup/src/projections/application_projection_source.dart';

final class _Owner extends ApplicationStateOwner {
  int value = 0;

  void replace(int next, {ApplicationCause? cause}) {
    value = next;
    publishChange(cause);
  }
}

void main() {
  test(
    'reads once per signal, suppresses equality, and carries cause',
    () async {
      final owner = _Owner();
      var reads = 0;
      final source = ApplicationProjectionSource<int>(
        changes: owner.changes,
        read: () {
          reads += 1;
          return owner.value;
        },
      );
      final updates = <ProjectionUpdate<int>>[];
      final subscription = source.changes.listen(updates.add);

      owner.replace(0);
      owner.replace(1, cause: const ApplicationCause(traceId: 'trace-a'));

      expect(reads, 3);
      expect(updates, hasLength(1));
      expect(source.current, 1);
      expect(updates.single.trace?.traceId, 'trace-a');

      await subscription.cancel();
      await source.dispose();
      owner.dispose();
    },
  );
}
