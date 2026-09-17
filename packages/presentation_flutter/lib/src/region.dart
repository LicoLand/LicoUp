import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

/// Ordinary component render callback. Components receive narrow values and
/// typed actions; they do not receive a Riverpod ref.
typedef RegionRenderer<Inputs, Actions> =
    Widget Function(BuildContext context, Inputs inputs, Actions actions);

/// Thin Flutter entry declaration over the official Riverpod listenable type.
///
/// The package intentionally does not implement a widget, subscription
/// registry, async state machine, or provider DSL in this slice.
abstract interface class Region<Inputs, Actions> {
  ProviderListenable<Inputs> get source;

  Actions get actions;

  RegionRenderer<Inputs, Actions> get render;
}
