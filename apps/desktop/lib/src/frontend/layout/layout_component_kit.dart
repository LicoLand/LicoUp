import 'package:flutter/widgets.dart';

/// Role contracts only. Every profile supplies its own styled implementation.
abstract interface class LayoutComponentKit {
  String get styleIdentity;

  Widget navigationItem(
    BuildContext context, {
    required Key key,
    required Widget icon,
    required String label,
    required bool selected,
    required VoidCallback onPressed,
  });

  Widget panel(
    BuildContext context, {
    required Key key,
    required Widget child,
    bool emphasized = false,
  });

  Widget card(
    BuildContext context, {
    required Key key,
    required Widget child,
    VoidCallback? onPressed,
  });

  Widget fieldFrame(
    BuildContext context, {
    required Key key,
    required Widget child,
    String? semanticLabel,
  });

  Widget dialogSurface(
    BuildContext context, {
    required Key key,
    required Widget child,
  });

  Widget statusSurface(
    BuildContext context, {
    required Key key,
    required Widget child,
    required bool attention,
  });
}
