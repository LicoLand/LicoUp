import 'dart:collection';

import 'layout_profile_copy.dart';
import 'layout_style.dart';

export 'layout_profile_copy.dart';

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

/// Public profile-owned metadata for Settings and preview surfaces.
final class LayoutProfileDescriptor
    implements Comparable<LayoutProfileDescriptor> {
  factory LayoutProfileDescriptor({
    required LayoutProfileId id,
    required LayoutProfileCopy label,
    required LayoutProfileCopy description,
    required String styleIdentity,
    required bool isDefault,
    bool selectable = true,
    int revision = 1,
    List<LayoutStyleDescriptor> styles = const [],
    LayoutStyleId? defaultStyleId,
  }) {
    if (!_styleIdentity.hasMatch(styleIdentity)) {
      throw const FormatException('layout_profile_style_identity_invalid');
    }
    if (revision < 1) {
      throw const FormatException('layout_profile_revision_invalid');
    }
    final declaredStyles = <LayoutStyleId>{};
    for (final style in styles) {
      if (!declaredStyles.add(style.id)) {
        throw const FormatException('layout_profile_styles_duplicate');
      }
    }
    if (styles.isEmpty && defaultStyleId != null) {
      throw const FormatException('layout_profile_default_style_unexpected');
    }
    if (styles.isNotEmpty) {
      if (defaultStyleId == null) {
        throw const FormatException('layout_profile_default_style_missing');
      }
      if (!declaredStyles.contains(defaultStyleId)) {
        throw const FormatException('layout_profile_default_style_unknown');
      }
    }
    return LayoutProfileDescriptor._(
      id: id,
      label: label,
      description: description,
      styleIdentity: styleIdentity,
      isDefault: isDefault,
      selectable: selectable,
      revision: revision,
      styles: UnmodifiableListView(List<LayoutStyleDescriptor>.of(styles)),
      defaultStyleId: defaultStyleId,
    );
  }

  const LayoutProfileDescriptor._({
    required this.id,
    required this.label,
    required this.description,
    required this.styleIdentity,
    required this.isDefault,
    required this.selectable,
    required this.revision,
    required this.styles,
    required this.defaultStyleId,
  });

  static final RegExp _styleIdentity = RegExp(r'^[a-z]+(?:-[a-z]+)*$');

  final LayoutProfileId id;
  final LayoutProfileCopy label;
  final LayoutProfileCopy description;
  final String styleIdentity;
  final bool isDefault;
  final bool selectable;
  final int revision;

  /// Column arrangements the profile offers on the desktop surface. Empty
  /// for single-arrangement profiles; then [defaultStyleId] is null.
  final List<LayoutStyleDescriptor> styles;

  /// The arrangement a profile starts on before the user's stored choice.
  /// Non-null exactly when [styles] is non-empty and always one of them.
  final LayoutStyleId? defaultStyleId;

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
          other.selectable == selectable &&
          other.revision == revision &&
          _sameStyleList(other.styles, styles) &&
          other.defaultStyleId == defaultStyleId;

  @override
  int get hashCode => Object.hash(
    id,
    label,
    description,
    styleIdentity,
    isDefault,
    selectable,
    revision,
    Object.hashAll(styles),
    defaultStyleId,
  );

  static bool _sameStyleList(
    List<LayoutStyleDescriptor> left,
    List<LayoutStyleDescriptor> right,
  ) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index += 1) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }
}
