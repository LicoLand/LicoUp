import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

/// Ordinary component render callback. Components receive narrow values and
/// typed actions; they do not receive a Riverpod ref.
typedef RegionRenderer<Inputs, Actions> =
    Widget Function(BuildContext context, Inputs inputs, Actions actions);

/// Thin Flutter entry declaration over the official Riverpod listenable type.
abstract interface class Region<Inputs, Actions> {
  /// Creates a thin [Region] declaration with a stable [source], typed [actions],
  /// and pure [render] callback.
  factory Region({
    required ProviderListenable<Inputs> source,
    required Actions actions,
    required RegionRenderer<Inputs, Actions> render,
  }) = _PureRegion<Inputs, Actions>;

  ProviderListenable<Inputs> get source;

  Actions get actions;

  RegionRenderer<Inputs, Actions> get render;
}

/// Thin [ConsumerWidget] that connects a [Region] (or direct [source]) to
/// Riverpod's [WidgetRef.watch] and invokes [Region.render].
///
/// Components receive narrow values and typed actions; they do not receive a Riverpod ref.
class ConsumerRegion<Inputs, Actions> extends ConsumerWidget {
  const ConsumerRegion({super.key, required this.region})
    : source = null,
      actions = null,
      render = null;

  const ConsumerRegion.from({
    super.key,
    required ProviderListenable<Inputs> this.source,
    required Actions this.actions,
    required RegionRenderer<Inputs, Actions> this.render,
  }) : region = null;

  final Region<Inputs, Actions>? region;
  final ProviderListenable<Inputs>? source;
  final Actions? actions;
  final RegionRenderer<Inputs, Actions>? render;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final effectiveSource = region?.source ?? source!;
    final effectiveActions = region?.actions ?? (actions as Actions);
    final effectiveRender = region?.render ?? render!;

    final inputs = ref.watch(effectiveSource);
    return effectiveRender(context, inputs, effectiveActions);
  }
}

/// Host alias for [ConsumerRegion] matching assembly and architecture conventions.
typedef RegionHost<Inputs, Actions> = ConsumerRegion<Inputs, Actions>;

/// Extension providing convenient widget construction from a [Region].
extension RegionWidgetExtension<Inputs, Actions> on Region<Inputs, Actions> {
  Widget toWidget({Key? key}) => ConsumerRegion(key: key, region: this);
}

final class _PureRegion<Inputs, Actions> implements Region<Inputs, Actions> {
  const _PureRegion({
    required this.source,
    required this.actions,
    required this.render,
  });

  @override
  final ProviderListenable<Inputs> source;

  @override
  final Actions actions;

  @override
  final RegionRenderer<Inputs, Actions> render;
}
