abstract final class LocalePreference {
  static const system = 'system';
  static const chinese = 'zh';
  static const english = 'en';
  static const values = [system, chinese, english];

  static String normalize(String value) {
    final normalized = value.trim().toLowerCase();
    return values.contains(normalized) ? normalized : system;
  }
}
