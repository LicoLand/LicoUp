import 'package:presentation_contract/presentation_contract.dart';

/// Why a value that was already read from a source lost its validity.
enum SourceInvalidationReason {
  /// A new incarnation of the source replaced the one that issued the previous
  /// position.
  ///
  /// Offsets, block identities, and prepared values cite a [SourceEpoch], so
  /// nothing prepared from the replaced epoch can be shown in the new one even
  /// when the text looks identical.
  epochReplaced,

  /// The application withdrew authority over the resource.
  revoked,
}

/// One presentation field group losing validity.
///
/// The application scope that owns the runtime receives this instead of a silent
/// value swap: withdrawal wins over [ConsistencyGroup] completeness, so derived
/// values are dropped before anything else installs.
final class SourceInvalidation {
  const SourceInvalidation({
    required this.reason,
    required this.fieldGroup,
    this.previous,
    this.position,
  });

  final SourceInvalidationReason reason;

  /// The presentation field group whose value is no longer valid.
  final ResourceFieldGroup<Object?> fieldGroup;

  /// The position that lost validity, when it was read.
  final SourcePosition? previous;

  /// The position that replaced it, when the replacement is already known.
  final SourcePosition? position;

  ResourceKey get resource => fieldGroup.resource;

  /// The incarnation that lost validity, when it was read.
  SourceEpoch? get replacedEpoch => previous?.epoch;

  @override
  String toString() =>
      'SourceInvalidation($reason, $fieldGroup, $previous -> $position)';
}
