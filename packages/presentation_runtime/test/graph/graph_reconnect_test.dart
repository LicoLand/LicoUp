import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/presentation_runtime.dart';
import 'package:test/test.dart';

import 'graph_preparation_test.dart'
    show TestGraphSource, document, nodeJson, until;

/// A revoked resource comes back only through a fresh read of the same source.
///
/// The runtime keeps one source instance per resource, so a reconnect is the
/// same producer reading again in a new epoch — not a second producer claiming
/// the same name. These tests pin that contract for the graph resource.
void main() {
  ResourceKey resource() => ResourceKey(
    scope: const ResourceScope('licoup.test.graph-reconnect'),
    stableKey: 'projects',
  );

  test(
    'a fresh incarnation of the same source is admitted after a revoke',
    () async {
      final runtime = PresentationRuntime();
      addTearDown(runtime.dispose);
      final field = graphDocumentFieldGroupFor(resource());
      final source = TestGraphSource(field);
      source.publish(
        document(
          revision: 1,
          nodes: <Map<String, Object?>>[nodeJson('licoup.node/a')],
        ),
        topologyChanged: true,
      );
      final ownership = runtime.own(source);
      addTearDown(ownership.release);
      final values = <int>[];
      ownership.subscribe().stream.listen(
        (snapshot) => values.add(snapshot.value.document.planRevision),
        // The withdrawal is reported on the raw stream; a subscriber that keeps
        // rendering its last value would otherwise never learn about it.
        onError: (Object _) {},
      );
      await until(() => runtime.current(field) != null, reason: 'first read');
      expect(runtime.current(field)!.value.document.planRevision, 1);

      runtime.revoke(resource());
      expect(runtime.current(field), isNull, reason: 'authority withdrawn');

      // The producer reads again in a new incarnation of the same source.
      source.reopen(
        document(
          revision: 3,
          nodes: <Map<String, Object?>>[
            nodeJson('licoup.node/a', execution: 'running'),
            nodeJson('licoup.node/b'),
          ],
        ),
        epochId: 'licoup.test.graph-reconnect/2',
      );
      await ownership.reconnect();
      await until(
        () => runtime.current(field) != null,
        reason: 'the fresh incarnation is admitted',
      );
      expect(runtime.current(field)!.value.document.planRevision, 3);
      expect(values, contains(3));
      await ownership.release();
    },
  );

  test('a second source instance is refused for the same resource', () {
    final runtime = PresentationRuntime();
    addTearDown(runtime.dispose);
    final field = graphDocumentFieldGroupFor(resource());
    final first = TestGraphSource(field);
    first.publish(
      document(
        revision: 1,
        nodes: <Map<String, Object?>>[nodeJson('licoup.node/a')],
      ),
      topologyChanged: true,
    );
    runtime.observe(first);
    expect(
      () => runtime.observe(TestGraphSource(field)),
      throwsA(isA<StateError>()),
      reason: 'two producers may not claim one resource name',
    );
  });
}
