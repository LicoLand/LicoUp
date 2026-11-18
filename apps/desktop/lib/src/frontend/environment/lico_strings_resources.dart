import 'package:flutter/widgets.dart';

import 'package:licoup/src/contracts/locale/locale_resource_pack.dart';
import 'package:licoup/src/presentation/environment/environment_projection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

/// The installed interface strings this client renders from.
///
/// Resources are addressed by base language tag and interface key. A language
/// no installed resource covers resolves to nothing, and the compiled baseline
/// renders instead, which is what a first launch — no installed resource and no
/// network — shows.
final class LicoStringResources {
  const LicoStringResources.empty()
    : _byLanguage = const <String, Map<String, String>>{};

  LicoStringResources(Iterable<LocaleResourceProjection> resources)
    : _byLanguage = _index(resources);

  /// The same resources as the application layer holds them.
  ///
  /// Non-widget consumers — the search catalogue indexes interface labels —
  /// resolve from here so an installed resource cannot say one thing in the
  /// sidebar and another in search.
  factory LicoStringResources.installed(Iterable<LocaleResourcePack> packs) =>
      LicoStringResources([
        for (final pack in packs)
          LocaleResourceProjection(
            id: pack.id,
            locale: pack.locale,
            strings: pack.strings,
          ),
      ]);

  final Map<String, Map<String, String>> _byLanguage;

  /// The installed string for [key] in [locale], or `null` when no installed
  /// resource defines it.
  String? lookup(Locale locale, String key) =>
      _byLanguage[normalizeLocaleResourceTag(locale.languageCode)]?[key];

  bool get isEmpty => _byLanguage.isEmpty;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LicoStringResources &&
          samePresentationMap(
            _flatten(other._byLanguage),
            _flatten(_byLanguage),
          );

  @override
  int get hashCode => Object.hashAllUnordered(_flatten(_byLanguage).entries);

  static Map<String, String> _flatten(Map<String, Map<String, String>> source) {
    final flat = <String, String>{};
    for (final entry in source.entries) {
      for (final string in entry.value.entries) {
        flat['${entry.key}.${string.key}'] = string.value;
      }
    }
    return flat;
  }

  /// Installs every loaded resource, one language at a time.
  ///
  /// A later resource wins a key an earlier one also defines, so the load order
  /// the catalogue reported is the precedence the interface uses.
  static Map<String, Map<String, String>> _index(
    Iterable<LocaleResourceProjection> resources,
  ) {
    final byLanguage = <String, Map<String, String>>{};
    for (final resource in resources) {
      final language = normalizeLocaleResourceTag(resource.locale);
      if (language.isEmpty) continue;
      (byLanguage[language] ??= <String, String>{}).addAll(resource.strings);
    }
    return <String, Map<String, String>>{
      for (final entry in byLanguage.entries)
        entry.key: Map<String, String>.unmodifiable(entry.value),
    };
  }
}

/// Publishes the installed language resources to the widgets below it.
///
/// [LicoStrings.of] reads this scope, so a rendered string comes from the
/// installed resource rather than from the compiled baseline.
class LicoLocaleResourceScope extends InheritedWidget {
  const LicoLocaleResourceScope({
    super.key,
    required this.resources,
    required super.child,
  });

  final LicoStringResources resources;

  /// The resources in scope, or `null` when the client installed none.
  static LicoStringResources? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<LicoLocaleResourceScope>()
      ?.resources;

  @override
  bool updateShouldNotify(LicoLocaleResourceScope oldWidget) =>
      oldWidget.resources != resources;
}
