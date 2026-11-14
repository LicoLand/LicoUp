/// Profile-owned copy for the client locales supported by this product.
///
/// Copy travels with the profile registration so adding a profile never adds
/// an identity branch to shared localization or Settings code.
final class LayoutProfileCopy {
  factory LayoutProfileCopy({
    required String english,
    required String chinese,
  }) {
    final normalizedEnglish = english.trim();
    final normalizedChinese = chinese.trim();
    if (!_copyValue.hasMatch(normalizedEnglish) ||
        !_copyValue.hasMatch(normalizedChinese)) {
      throw const FormatException('layout_profile_copy_invalid');
    }
    return LayoutProfileCopy._(
      english: normalizedEnglish,
      chinese: normalizedChinese,
    );
  }

  const LayoutProfileCopy._({required this.english, required this.chinese});

  static final RegExp _copyValue = RegExp(r'^[^\u0000-\u001f\u007f]{1,512}$');

  final String english;
  final String chinese;

  String resolve(String languageCode) =>
      languageCode.toLowerCase() == 'zh' ? chinese : english;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LayoutProfileCopy &&
          other.english == english &&
          other.chinese == chinese;

  @override
  int get hashCode => Object.hash(english, chinese);
}
