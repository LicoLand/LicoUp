import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_client/src/contracts/presentation/destinations/destinations.dart';
import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_destination_port_mount.dart';

void main() {
  const contract = LayoutDestinationContract<_Snapshot>(
    key: LayoutDestinationContractKey(
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.agents,
    ),
  );

  testWidgets('lease exists only while the destination renderer is mounted', (
    tester,
  ) async {
    final port = _Port(contract, const _Snapshot('ready'));
    final resolver = LayoutDestinationPortResolver([
      LayoutDestinationPortBinding(port),
    ]);

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: LayoutDestinationPortMount<_Snapshot>(
          resolver: resolver,
          contract: contract,
          builder: (context, mountedPort) => Text(mountedPort.snapshot.value),
        ),
      ),
    );

    expect(find.text('ready'), findsOneWidget);
    expect(resolver.activeLeaseCount, 1);

    await tester.pumpWidget(const SizedBox.shrink());

    expect(resolver.activeLeaseCount, 0);
    resolver.close();
    expect(resolver.isClosed, isTrue);
  });

  testWidgets('resolver replacement releases before acquiring the successor', (
    tester,
  ) async {
    final first = LayoutDestinationPortResolver([
      LayoutDestinationPortBinding(_Port(contract, const _Snapshot('first'))),
    ]);
    final second = LayoutDestinationPortResolver([
      LayoutDestinationPortBinding(_Port(contract, const _Snapshot('second'))),
    ]);

    Widget app(LayoutDestinationPortResolver resolver) => Directionality(
      textDirection: TextDirection.ltr,
      child: LayoutDestinationPortMount<_Snapshot>(
        resolver: resolver,
        contract: contract,
        builder: (context, port) => Text(port.snapshot.value),
      ),
    );

    await tester.pumpWidget(app(first));
    expect(first.activeLeaseCount, 1);

    await tester.pumpWidget(app(second));
    expect(find.text('second'), findsOneWidget);
    expect(first.activeLeaseCount, 0);
    expect(second.activeLeaseCount, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(second.activeLeaseCount, 0);
  });
}

final class _Snapshot {
  const _Snapshot(this.value);

  final String value;
}

final class _Port implements LayoutDestinationPort<_Snapshot> {
  _Port(this.contract, this.snapshot);

  @override
  final LayoutDestinationContract<_Snapshot> contract;

  @override
  final _Snapshot snapshot;

  @override
  LayoutDestinationSnapshotSubscription listen(
    LayoutDestinationSnapshotListener<_Snapshot> listener, {
    bool emitCurrent = true,
  }) {
    if (emitCurrent) {
      listener(snapshot);
    }
    return _Subscription();
  }
}

final class _Subscription implements LayoutDestinationSnapshotSubscription {
  bool _cancelled = false;

  @override
  bool get isCancelled => _cancelled;

  @override
  void cancel() => _cancelled = true;
}
