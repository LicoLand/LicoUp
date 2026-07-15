import 'package:flutter/widgets.dart';

import 'package:flutter_client/src/contracts/presentation/destinations/destinations.dart';

typedef LayoutDestinationPortWidgetBuilder<Snapshot extends Object> =
    Widget Function(BuildContext context, LayoutDestinationPort<Snapshot> port);

/// Owns one typed destination-port lease for exactly one mounted renderer.
///
/// The host remains type-erased while a profile-owned destination receives
/// only the semantic port declared by its renderer contract. Replacing the
/// resolver or contract releases the old lease before the new tree builds.
final class LayoutDestinationPortMount<Snapshot extends Object>
    extends StatefulWidget {
  const LayoutDestinationPortMount({
    super.key,
    required this.resolver,
    required this.contract,
    required this.builder,
  });

  final LayoutDestinationPortResolver resolver;
  final LayoutDestinationContract<Snapshot> contract;
  final LayoutDestinationPortWidgetBuilder<Snapshot> builder;

  @override
  State<LayoutDestinationPortMount<Snapshot>> createState() =>
      _LayoutDestinationPortMountState<Snapshot>();
}

final class _LayoutDestinationPortMountState<Snapshot extends Object>
    extends State<LayoutDestinationPortMount<Snapshot>> {
  late LayoutDestinationPortLease<Snapshot> _lease = _acquire();

  LayoutDestinationPortLease<Snapshot> _acquire() =>
      widget.resolver.acquire(widget.contract);

  @override
  void didUpdateWidget(LayoutDestinationPortMount<Snapshot> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.resolver, widget.resolver) &&
        oldWidget.contract == widget.contract) {
      return;
    }
    oldWidget.resolver.release(_lease);
    _lease = _acquire();
  }

  @override
  void dispose() {
    widget.resolver.release(_lease);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _lease.port);
}
