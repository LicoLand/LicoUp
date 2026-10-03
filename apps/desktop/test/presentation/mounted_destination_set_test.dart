import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/presentation/mounted_destination_set.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';

void main() {
  test('a full declaration mounts every canonical destination in order', () {
    final mounts = MountedDestinationSet(ClientSection.values);

    expect(mounts.destinations, ClientSection.values);
    expect(mounts.recoveryFor(ClientSection.settings), ClientSection.settings);
    for (final destination in ClientSection.values) {
      expect(mounts.isMounted(destination), isTrue, reason: '$destination');
    }
  });

  test('an absent capability is reported absent and recovers to a mount', () {
    final mounts = MountedDestinationSet(const [
      ClientSection.agents,
      ClientSection.monitoring,
    ]);

    expect(mounts.isMounted(ClientSection.settings), isFalse);
    expect(mounts.isMounted(ClientSection.skillHub), isFalse);
    expect(mounts.isMounted(ClientSection.agents), isTrue);
    expect(mounts.destinations, const [
      ClientSection.agents,
      ClientSection.monitoring,
    ]);
    expect(
      mounts.recoveryFor(ClientSection.settings),
      ClientSection.agents,
      reason: 'the agent destination is the entry point every client serves',
    );
  });

  test('recovery falls back to the first canonical mount without agents', () {
    final mounts = MountedDestinationSet(const [
      ClientSection.models,
      ClientSection.agents,
    ]);

    expect(mounts.destinations, const [
      ClientSection.agents,
      ClientSection.models,
    ]);
    expect(mounts.recoveryFor(ClientSection.skillHub), ClientSection.agents);
    expect(
      MountedDestinationSet(const [
        ClientSection.models,
      ]).recoveryFor(ClientSection.skillHub),
      ClientSection.models,
    );
  });

  test('a client that mounts nothing recovers to nothing', () {
    final mounts = MountedDestinationSet(const <ClientSection>[]);

    expect(mounts.destinations, isEmpty);
    expect(mounts.isMounted(ClientSection.agents), isFalse);
    expect(mounts.recoveryFor(ClientSection.agents), isNull);
  });

  test('the projection is immutable and value-equal', () {
    final mounts = MountedDestinationSet(const [
      ClientSection.settings,
      ClientSection.agents,
      ClientSection.agents,
    ]);

    expect(mounts.destinations, const [
      ClientSection.agents,
      ClientSection.settings,
    ]);
    expect(
      () => mounts.destinations.add(ClientSection.models),
      throwsUnsupportedError,
    );
    expect(
      () => mounts.mounted.add(ClientSection.models),
      throwsUnsupportedError,
    );
    expect(
      mounts,
      MountedDestinationSet(const [
        ClientSection.agents,
        ClientSection.settings,
      ]),
    );
    expect(mounts, isNot(MountedDestinationSet(const [ClientSection.agents])));
  });
}
