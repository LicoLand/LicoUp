import 'package:flutter/foundation.dart';

/// Stable semantic identity for a complete presentation profile.
final class LayoutProfileId implements Comparable<LayoutProfileId> {
  const LayoutProfileId._(this.value);

  factory LayoutProfileId.parse(String value) {
    final normalized = value.trim();
    final segments = normalized.split('-');
    if (!_semanticId.hasMatch(normalized) ||
        segments.any(_retiredIdentitySegments.contains)) {
      throw const FormatException('invalid_layout_profile_id');
    }
    return LayoutProfileId._(normalized);
  }

  static final RegExp _semanticId = RegExp(r'^[a-z]+(?:-[a-z]+)*$');
  static const _retiredIdentitySegments = {
    'legacy',
    'compat',
    'compatible',
    'compatibility',
    'version',
    'versioned',
    'v',
  };

  final String value;

  @override
  int compareTo(LayoutProfileId other) => value.compareTo(other.value);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LayoutProfileId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// Sole platform policy for choosing the preferred catalog profile.
///
/// The catalog remains the source of profile membership and declared default
/// metadata. This policy selects the current product's platform preference;
/// callers inject the result into manager, recovery, persistence, and reset.
abstract final class LayoutProfileDefaults {
  /// Platform-preferred layout for first run and "restore default".
  static LayoutProfileId preferredForPlatform(TargetPlatform platform) {
    return switch (platform) {
      TargetPlatform.macOS ||
      TargetPlatform.windows ||
      TargetPlatform.iOS ||
      TargetPlatform.android => LayoutProfileId.parse('messaging'),
      _ => LayoutProfileId.parse('dashboard'),
    };
  }
}

/// Profile-owned copy for the client locales supported by this product.
///
/// Copy travels with the profile registration so adding a profile never adds
/// an identity branch to shared localization or Settings code.
@immutable
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

/// Public profile-owned metadata for Settings and preview surfaces.
final class LayoutProfileDescriptor
    implements Comparable<LayoutProfileDescriptor> {
  factory LayoutProfileDescriptor({
    required LayoutProfileId id,
    required LayoutProfileCopy label,
    required LayoutProfileCopy description,
    required String styleIdentity,
    required bool isDefault,
    int revision = 1,
  }) {
    if (!_styleIdentity.hasMatch(styleIdentity)) {
      throw const FormatException('layout_profile_style_identity_invalid');
    }
    if (revision < 1) {
      throw const FormatException('layout_profile_revision_invalid');
    }
    return LayoutProfileDescriptor._(
      id: id,
      label: label,
      description: description,
      styleIdentity: styleIdentity,
      isDefault: isDefault,
      revision: revision,
    );
  }

  const LayoutProfileDescriptor._({
    required this.id,
    required this.label,
    required this.description,
    required this.styleIdentity,
    required this.isDefault,
    required this.revision,
  });

  static final RegExp _styleIdentity = RegExp(r'^[a-z]+(?:-[a-z]+)*$');

  final LayoutProfileId id;
  final LayoutProfileCopy label;
  final LayoutProfileCopy description;
  final String styleIdentity;
  final bool isDefault;
  final int revision;

  @override
  int compareTo(LayoutProfileDescriptor other) => id.compareTo(other.id);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LayoutProfileDescriptor &&
          other.id == id &&
          other.label == label &&
          other.description == description &&
          other.styleIdentity == styleIdentity &&
          other.isDefault == isDefault &&
          other.revision == revision;

  @override
  int get hashCode =>
      Object.hash(id, label, description, styleIdentity, isDefault, revision);
}
