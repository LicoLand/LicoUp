import 'package:licoup/src/application/state/application_signal.dart';

/// Tone for chrome-band notification-center rows.
enum MessagingNotificationTone { info, warning, failure, success }

/// One user-visible operation-feedback item in the top-right notification
/// center. Uses a stable [id] so refreshes replace rather than duplicate.
final class MessagingNotificationItem {
  const MessagingNotificationItem({
    required this.id,
    required this.messageChinese,
    required this.messageEnglish,
    required this.tone,
    required this.createdAt,
    this.code = '',
  });

  final String id;
  final String messageChinese;
  final String messageEnglish;
  final MessagingNotificationTone tone;
  final String code;
  final DateTime createdAt;

  String messageForLocale({required bool chinese}) =>
      chinese ? messageChinese : messageEnglish;
}

/// Shared model for messaging chrome notification-center feedback.
///
/// Design system: the top-right bell is the single destination for
/// user-visible success / warning / failure after an action starts. Feature
/// pages must not invent parallel snack bars for the same events.
final class MessagingNotificationCenter extends ApplicationStateOwner {
  final Map<String, MessagingNotificationItem> _byId =
      <String, MessagingNotificationItem>{};
  int _revision = 0;

  /// Monotonic counter bumped on every [publish] so chrome can auto-open.
  int get revision => _revision;

  List<MessagingNotificationItem> get items {
    final list = _byId.values.toList(growable: false);
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  bool get hasItems => _byId.isNotEmpty;

  bool get hasWarningOrFailure => _byId.values.any(
    (item) =>
        item.tone == MessagingNotificationTone.warning ||
        item.tone == MessagingNotificationTone.failure,
  );

  void publish({
    required String id,
    required String messageChinese,
    required String messageEnglish,
    MessagingNotificationTone tone = MessagingNotificationTone.info,
    String code = '',
  }) {
    final key = id.trim();
    if (key.isEmpty) return;
    _byId[key] = MessagingNotificationItem(
      id: key,
      messageChinese: messageChinese.trim(),
      messageEnglish: messageEnglish.trim(),
      tone: tone,
      code: code.trim(),
      createdAt: DateTime.now().toUtc(),
    );
    _revision += 1;
    publishChange();
  }

  void dismiss(String id) {
    if (_byId.remove(id.trim()) == null) return;
    publishChange();
  }

  void clear() {
    if (_byId.isEmpty) return;
    _byId.clear();
    publishChange();
  }
}
