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

  static const workbench = LayoutProfileId._('workbench');
  static const studio = LayoutProfileId._('studio');

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

/// Public, localization-keyed metadata for Settings and preview surfaces.
final class LayoutProfileDescriptor
    implements Comparable<LayoutProfileDescriptor> {
  factory LayoutProfileDescriptor({
    required LayoutProfileId id,
    required String labelKey,
    required String descriptionKey,
    required String styleIdentity,
    required bool isDefault,
    int revision = 1,
  }) {
    if (!_metadataKey.hasMatch(labelKey) ||
        !_metadataKey.hasMatch(descriptionKey)) {
      throw const FormatException('layout_profile_metadata_key_invalid');
    }
    if (!_styleIdentity.hasMatch(styleIdentity)) {
      throw const FormatException('layout_profile_style_identity_invalid');
    }
    if (revision < 1) {
      throw const FormatException('layout_profile_revision_invalid');
    }
    return LayoutProfileDescriptor._(
      id: id,
      labelKey: labelKey,
      descriptionKey: descriptionKey,
      styleIdentity: styleIdentity,
      isDefault: isDefault,
      revision: revision,
    );
  }

  const LayoutProfileDescriptor._({
    required this.id,
    required this.labelKey,
    required this.descriptionKey,
    required this.styleIdentity,
    required this.isDefault,
    required this.revision,
  });

  static final RegExp _metadataKey = RegExp(
    r'^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$',
  );
  static final RegExp _styleIdentity = RegExp(r'^[a-z]+(?:-[a-z]+)*$');

  final LayoutProfileId id;
  final String labelKey;
  final String descriptionKey;
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
          other.labelKey == labelKey &&
          other.descriptionKey == descriptionKey &&
          other.styleIdentity == styleIdentity &&
          other.isDefault == isDefault &&
          other.revision == revision;

  @override
  int get hashCode => Object.hash(
    id,
    labelKey,
    descriptionKey,
    styleIdentity,
    isDefault,
    revision,
  );
}
