import 'package:licoup/src/application/state/application_signal.dart';

/// Owns locale-neutral functional status facts.
final class FunctionalStatusRuntime extends ApplicationStateOwner {
  FunctionalStatusRuntime({
    String messageChinese = '等待扫描目标适配器。',
    String messageEnglish = 'Waiting to scan target adapters.',
    String caption = 'LicoUp client',
  }) : _messageSource = messageChinese,
       _messageChinese = messageChinese,
       _messageEnglish = messageEnglish,
       _caption = caption;

  static final RegExp _stableCode = RegExp(
    r'^[a-z][a-z0-9]*(?:[._:-][a-z0-9]+)*$',
  );

  String _messageSource;
  String _messageChinese;
  String _messageEnglish;
  String _caption;
  String _lastError = '';
  String _lastErrorCode = '';

  String get messageSource => _messageSource;
  String get messageChinese => _messageChinese;
  String get messageEnglish => _messageEnglish;
  String get caption => _caption;
  String get lastError => _lastError;
  String get lastErrorCode => _lastErrorCode;

  void setLocalized(
    String chinese,
    String english, {
    required String caption,
    String errorCode = '',
    String? displayChinese,
  }) {
    _messageSource = chinese;
    _messageChinese = displayChinese ?? chinese;
    _messageEnglish = english;
    _caption = caption;
    if (errorCode.isNotEmpty) {
      _lastError = errorCode;
      _lastErrorCode = _safeCode(errorCode);
    }
    publishChange();
  }

  void replaceMessage(String value) {
    _messageSource = value;
    _messageChinese = value;
    _messageEnglish = value;
    publishChange();
  }

  void replaceCaption(String value) {
    if (_caption == value) return;
    _caption = value;
    publishChange();
  }

  void replaceLastError(String value) {
    _lastError = value;
    _lastErrorCode = _safeCode(value);
    publishChange();
  }

  static String _safeCode(String value) {
    final normalized = value.trim().toLowerCase();
    return _stableCode.hasMatch(normalized) ? normalized : '';
  }
}
