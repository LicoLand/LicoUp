import 'package:licoup/src/contracts/agent_conversation_session.dart';

String conversationSessionRelativeUpdatedAtLabel(
  AgentConversationSession session, {
  bool chinese = false,
}) {
  final rawUpdatedAt = session.updatedAt.trim().isEmpty
      ? session.createdAt.trim()
      : session.updatedAt.trim();
  final updatedAt = DateTime.tryParse(rawUpdatedAt)?.toLocal();
  if (updatedAt == null) {
    return rawUpdatedAt;
  }
  return conversationRelativeUpdatedAtLabel(updatedAt, chinese: chinese);
}

/// The shared conversation clock — injectable for deterministic tests.
DateTime Function() conversationNow = DateTime.now;

/// The Demo's conversation-list clock: same-day times render `HH:mm`, then
/// 昨天/Yesterday, weekday names inside the current week, and `M/d` beyond.
String conversationRelativeUpdatedAtLabel(
  DateTime updatedAt, {
  bool chinese = false,
}) {
  final now = conversationNow();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(updatedAt.year, updatedAt.month, updatedAt.day);
  final dayDiff = today.difference(day).inDays;
  if (dayDiff <= 0) {
    final h = updatedAt.hour.toString().padLeft(2, '0');
    final m = updatedAt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
  if (dayDiff == 1) {
    return chinese ? '昨天' : 'Yesterday';
  }
  if (dayDiff < 7) {
    const zhWeekdays = ['一', '二', '三', '四', '五', '六', '日'];
    const enWeekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final weekday = updatedAt.weekday - 1;
    return chinese ? '周${zhWeekdays[weekday]}' : enWeekdays[weekday];
  }
  return '${updatedAt.month}/${updatedAt.day}';
}
