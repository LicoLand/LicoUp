import 'dart:convert';

/// The published shape of a language resource document.
///
/// One data resource of kind `language` declares the locale tags it covers and
/// names the document that carries them; this is that document. The client reads
/// the installed document and resolves interface keys from it, so an installed
/// resource changes what the client renders without a new build.
const String languageResourceFormat = 'licoup.data.language.v1';

/// The longest locale tag accepted, matching the manifest contract bound.
const int maxLocaleResourceTagBytes = 35;

/// The most interface keys one language resource may carry.
const int maxLocaleResourceKeys = 4096;

/// The longest interface key accepted.
const int maxLocaleResourceKeyBytes = 120;

/// The longest one interface value accepted.
const int maxLocaleResourceValueBytes = 4096;

/// One installed set of interface strings for one locale.
///
/// The locale is normalized to its base language tag (`zh-CN` and `zh-Hans`
/// both address `zh`), because the client's interface languages are its base
/// languages; a regional variant is a resource for the same interface.
final class LocaleResourcePack {
  LocaleResourcePack({
    required this.id,
    required String locale,
    required Map<String, String> strings,
  }) : locale = normalizeLocaleResourceTag(locale),
       strings = Map<String, String>.unmodifiable(strings);

  /// The resource identity the package declared.
  final String id;

  /// The base language tag this resource supplies strings for.
  final String locale;

  /// Interface key to rendered string.
  final Map<String, String> strings;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LocaleResourcePack &&
          other.id == id &&
          other.locale == locale &&
          _sameStrings(other.strings, strings);

  @override
  int get hashCode =>
      Object.hash(id, locale, Object.hashAllUnordered(strings.entries));

  @override
  String toString() =>
      'LocaleResourcePack($id, $locale, ${strings.length} keys)';

  static bool _sameStrings(Map<String, String> left, Map<String, String> right) {
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      if (right[entry.key] != entry.value) return false;
    }
    return true;
  }
}

/// The base language tag an interface language is addressed by.
///
/// A resource that declares `zh-CN`, `zh-Hans` or `zh_CN` supplies the `zh`
/// interface; a tag with no letters is refused rather than guessed at.
String normalizeLocaleResourceTag(String value) {
  final normalized = value.trim().toLowerCase().replaceAll('_', '-');
  final separator = normalized.indexOf('-');
  return separator == -1 ? normalized : normalized.substring(0, separator);
}

/// Parses one installed language resource document.
///
/// Returns `null` when the document is not a language resource this client can
/// use; the caller records that as a load error instead of rendering partial
/// strings, because a resource the host cannot type is not one it can mount.
LocaleResourcePack? parseLocaleResourceDocument(Object? value) {
  if (value is! Map) return null;
  if (value['format'] != languageResourceFormat) return null;
  final id = value['id'];
  final locale = value['locale'];
  final strings = value['strings'];
  if (id is! String || id.trim().isEmpty || id.length > 200) return null;
  if (locale is! String ||
      locale.trim().isEmpty ||
      locale.length > maxLocaleResourceTagBytes) {
    return null;
  }
  if (normalizeLocaleResourceTag(locale).isEmpty) return null;
  if (strings is! Map || strings.length > maxLocaleResourceKeys) return null;
  final parsed = <String, String>{};
  for (final entry in strings.entries) {
    final key = entry.key;
    final text = entry.value;
    if (key is! String || key.isEmpty || key.length > maxLocaleResourceKeyBytes) {
      return null;
    }
    if (text is! String || text.length > maxLocaleResourceValueBytes) return null;
    parsed[key] = text;
  }
  return LocaleResourcePack(id: id.trim(), locale: locale, strings: parsed);
}

/// Parses one installed language resource document from its encoded text.
LocaleResourcePack? decodeLocaleResourceDocument(String source) {
  try {
    return parseLocaleResourceDocument(jsonDecode(source));
  } on FormatException {
    return null;
  }
}
