import 'layout_profile_copy.dart';

/// Stable semantic identity for one column arrangement inside a layout
/// profile.
///
/// Styles are profile-owned: the same id in two profiles names unrelated
/// arrangements, and persistence keys each style by its profile id.
final class LayoutStyleId implements Comparable<LayoutStyleId> {
  const LayoutStyleId._(this.value);

  factory LayoutStyleId.parse(String value) {
    final normalized = value.trim();
    if (!_semanticId.hasMatch(normalized)) {
      throw const FormatException('invalid_layout_style_id');
    }
    return LayoutStyleId._(normalized);
  }

  static final RegExp _semanticId = RegExp(r'^[a-z]+(?:-[a-z]+)*$');

  final String value;

  @override
  int compareTo(LayoutStyleId other) => value.compareTo(other.value);

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is LayoutStyleId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// Profile-owned metadata for one selectable column arrangement.
final class LayoutStyleDescriptor implements Comparable<LayoutStyleDescriptor> {
  const LayoutStyleDescriptor({required this.id, required this.label});

  final LayoutStyleId id;
  final LayoutProfileCopy label;

  @override
  int compareTo(LayoutStyleDescriptor other) => id.compareTo(other.id);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LayoutStyleDescriptor && other.id == id && other.label == label;

  @override
  int get hashCode => Object.hash(id, label);
}
