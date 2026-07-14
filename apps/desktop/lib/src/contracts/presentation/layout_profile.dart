import 'dart:collection';

/// Stable semantic identity for a complete presentation profile.
final class LayoutProfileId implements Comparable<LayoutProfileId> {
  const LayoutProfileId._(this.value);

  factory LayoutProfileId.parse(String value) {
    final normalized = value.trim();
    if (!_semanticId.hasMatch(normalized) ||
        _retiredIdentitySegments.contains(normalized)) {
      throw const FormatException('invalid_layout_profile_id');
    }
    return LayoutProfileId._(normalized);
  }

  static final RegExp _semanticId = RegExp(r'^[a-z]+(?:-[a-z]+)*$');
  static const _retiredIdentitySegments = {'legacy', 'compat', 'compatible'};

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

/// Layout metadata that is safe to expose in Settings and previews.
final class LayoutProfileDescriptor {
  LayoutProfileDescriptor({
    required this.id,
    required Map<String, String> labels,
    required Map<String, String> descriptionKeys,
    required this.styleIdentity,
    required this.isDefault,
    this.revision = 1,
  }) : labels = UnmodifiableMapView(Map<String, String>.of(labels)),
       descriptionKeys = UnmodifiableMapView(
         Map<String, String>.of(descriptionKeys),
       ) {
    if (labels.isEmpty || !labels.containsKey('en')) {
      throw const FormatException('layout_profile_label_missing');
    }
    if (styleIdentity.trim().isEmpty) {
      throw const FormatException('layout_profile_style_identity_missing');
    }
    if (revision < 1) {
      throw const FormatException('layout_profile_revision_invalid');
    }
  }

  final LayoutProfileId id;
  final Map<String, String> labels;
  final Map<String, String> descriptionKeys;
  final String styleIdentity;
  final bool isDefault;
  final int revision;

  String labelFor(String locale) => labels[locale] ?? labels['en']!;
}
