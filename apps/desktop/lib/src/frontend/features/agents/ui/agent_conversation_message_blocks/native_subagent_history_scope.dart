import 'package:flutter/widgets.dart';

import 'package:licoup/src/presentation/conversation/conversation_projection.dart';

/// The selected native conversation's child pages, shared by every nested card.
class NativeSubagentHistoryScope extends InheritedModel<String> {
  NativeSubagentHistoryScope({
    super.key,
    required Iterable<NativeChildConversationProjection> histories,
    required this.onLoad,
    required super.child,
  }) : histories = {
         for (final history in histories) history.sessionId: history,
       };

  final Map<String, NativeChildConversationProjection> histories;
  final void Function(String childSessionId, bool earlier) onLoad;

  static NativeSubagentHistoryScope? maybeOf(
    BuildContext context,
    String childSessionId,
  ) => InheritedModel.inheritFrom<NativeSubagentHistoryScope>(
    context,
    aspect: childSessionId,
  );

  @override
  bool updateShouldNotify(NativeSubagentHistoryScope oldWidget) => true;

  @override
  bool updateShouldNotifyDependent(
    NativeSubagentHistoryScope oldWidget,
    Set<String> dependencies,
  ) => dependencies.any((id) => histories[id] != oldWidget.histories[id]);
}
