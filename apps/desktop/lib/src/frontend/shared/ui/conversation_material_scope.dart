import 'package:flutter/widgets.dart';

/// Profile-owned material intent. Shared bubbles do not inspect layout IDs.
class ConversationMaterialScope extends InheritedWidget {
  const ConversationMaterialScope({
    super.key,
    required this.opaqueBubbles,
    required super.child,
  });

  final bool opaqueBubbles;

  static bool opaqueBubblesOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<ConversationMaterialScope>()
          ?.opaqueBubbles ??
      false;

  @override
  bool updateShouldNotify(ConversationMaterialScope oldWidget) =>
      oldWidget.opaqueBubbles != opaqueBubbles;
}
