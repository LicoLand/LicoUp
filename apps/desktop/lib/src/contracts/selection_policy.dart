/// The desktop side of the durable selection policy: the revision in force, the
/// preferences it contributes, and the revision a transition would adopt.
///
/// This file parses what the native owner renders through the `selection.policy.*`
/// methods and builds the documents those methods accept. The owner is the only
/// writer of the register (`domain::client_conversation::selection_policy`), so
/// nothing here decides a transition, invents a preference or derives a revision
/// identity: a client that needs a policy change sends a revision it was given.
///
/// Every field is bounded and defensively parsed. Identity, provenance and
/// preference values that are empty, over-long or control-bearing are refused
/// rather than repaired, because a revision the owner would reject must not read
/// as one it accepted.
library;

import 'package:licoup/src/contracts/generated/client_error.g.dart';

/// The revision name the owner reports when no revision is in force.
const String selectionPolicyUnadoptedRevision = 'unadopted';

/// The longest identity, provenance or preference value this contract carries.
const int selectionPolicyMaxValueLength = 256;

/// The longest preference list this contract carries.
const int selectionPolicyMaxListEntries = 64;

/// The code the owner reports when the stored register cannot be read.
///
/// It is read from the generated client-error contract rather than retyped, so
/// the client's spelling of the refusal cannot drift from the owner's.
final String selectionPolicyUnavailableCode =
    ClientErrorCode.selectionPolicyUnavailable.wireName;

String? _boundedText(
  Object? value, {
  int maxLength = selectionPolicyMaxValueLength,
}) {
  if (value is! String) return null;
  final text = value.trim();
  if (text.isEmpty || text.length > maxLength) return null;
  for (final codeUnit in text.codeUnits) {
    if (codeUnit < 0x20 || codeUnit == 0x7f) return null;
  }
  return text;
}

List<String> _boundedList(Object? value) {
  if (value is! List) return const <String>[];
  final entries = <String>[];
  for (final entry in value) {
    if (entries.length >= selectionPolicyMaxListEntries) break;
    final text = _boundedText(entry);
    if (text != null) entries.add(text);
  }
  return List<String>.unmodifiable(entries);
}

/// The candidate-ordering preferences one adopted revision contributes.
///
/// Every member is a preference, never a requirement: it orders the candidates a
/// request already allows, and the request's own preference wins. An empty
/// preference carries no ordering at all.
final class SelectionPolicyPreferences {
  const SelectionPolicyPreferences({
    this.preferredModel,
    this.preferredEnvironment,
    this.preferredSkills = const <String>[],
    this.preferredCapabilities = const <String>[],
    this.preferredTask,
  });

  final String? preferredModel;
  final String? preferredEnvironment;
  final List<String> preferredSkills;
  final List<String> preferredCapabilities;
  final String? preferredTask;

  /// Whether this revision states no preference at all.
  bool get isEmpty =>
      preferredModel == null &&
      preferredEnvironment == null &&
      preferredSkills.isEmpty &&
      preferredCapabilities.isEmpty &&
      preferredTask == null;

  /// Parse the preferences as the owner states them.
  ///
  /// A preference that cannot be read as stated is dropped rather than
  /// substituted: an unreadable ordering must not become a different one.
  static SelectionPolicyPreferences parse(Object? json) {
    final map = json is Map ? json : const <Object?, Object?>{};
    return SelectionPolicyPreferences(
      preferredModel: _boundedText(map['preferredModel']),
      preferredEnvironment: _boundedText(map['preferredEnvironment']),
      preferredSkills: _boundedList(map['preferredSkills']),
      preferredCapabilities: _boundedList(map['preferredCapabilities']),
      preferredTask: _boundedText(map['preferredTask']),
    );
  }

  /// The request document, carrying only the preferences that are stated.
  Map<String, Object?> toJson() => <String, Object?>{
    if (preferredModel != null) 'preferredModel': preferredModel,
    if (preferredEnvironment != null)
      'preferredEnvironment': preferredEnvironment,
    if (preferredSkills.isNotEmpty) 'preferredSkills': preferredSkills,
    if (preferredCapabilities.isNotEmpty)
      'preferredCapabilities': preferredCapabilities,
    if (preferredTask != null) 'preferredTask': preferredTask,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SelectionPolicyPreferences &&
          other.preferredModel == preferredModel &&
          other.preferredEnvironment == preferredEnvironment &&
          _sameList(other.preferredSkills, preferredSkills) &&
          _sameList(other.preferredCapabilities, preferredCapabilities) &&
          other.preferredTask == preferredTask;

  @override
  int get hashCode => Object.hash(
    preferredModel,
    preferredEnvironment,
    Object.hashAll(preferredSkills),
    Object.hashAll(preferredCapabilities),
    preferredTask,
  );

  @override
  String toString() =>
      'SelectionPolicyPreferences(model=$preferredModel, '
      'skills=${preferredSkills.length}, '
      'capabilities=${preferredCapabilities.length})';
}

/// One adopted selection-policy revision and the identity it replaced.
final class SelectionPolicyRevision {
  const SelectionPolicyRevision({
    required this.revisionId,
    required this.provenance,
    this.parentRevisionId,
    this.preferences = const SelectionPolicyPreferences(),
  });

  /// The stable identity of this revision, chosen by its producer.
  final String revisionId;

  /// The identity of the revision in force before this one. `null` is the first
  /// adoption: nothing preceded it.
  final String? parentRevisionId;

  /// The producer's own evidence reference for this revision. The owner keeps it
  /// opaque and never interprets it, so this contract only bounds it.
  final String provenance;

  final SelectionPolicyPreferences preferences;

  /// Whether this revision states nothing preceded it.
  bool get isFirstAdoption => parentRevisionId == null;

  /// Parse one revision, or refuse it.
  ///
  /// A revision the owner would refuse — an empty identity or provenance, or a
  /// value this contract cannot bound — is refused here as well, so a caller
  /// never sends a document whose rejection it could have known.
  static SelectionPolicyRevision? parse(Object? json) {
    final map = json is Map ? json : const <Object?, Object?>{};
    final revisionId = _boundedText(map['revisionId']);
    final provenance = _boundedText(map['provenance']);
    if (revisionId == null || provenance == null) return null;
    return SelectionPolicyRevision(
      revisionId: revisionId,
      parentRevisionId: _boundedText(map['parentRevisionId']),
      provenance: provenance,
      preferences: SelectionPolicyPreferences.parse(map['preferences']),
    );
  }

  /// The request document for `selection.policy.adopt` and `.supersede`.
  Map<String, Object?> toJson() => <String, Object?>{
    'revisionId': revisionId,
    if (parentRevisionId != null) 'parentRevisionId': parentRevisionId,
    'provenance': provenance,
    'preferences': preferences.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SelectionPolicyRevision &&
          other.revisionId == revisionId &&
          other.parentRevisionId == parentRevisionId &&
          other.provenance == provenance &&
          other.preferences == preferences;

  @override
  int get hashCode =>
      Object.hash(revisionId, parentRevisionId, provenance, preferences);

  @override
  String toString() =>
      'SelectionPolicyRevision($revisionId, parent=$parentRevisionId)';
}

/// The policy a newly admitted task is bound to, as the owner reports it.
///
/// It is the value the owner captured at the admission boundary, not a view the
/// client recomputes: a later supersede changes what the *next* task is admitted
/// under and leaves this binding as it was.
final class SelectionPolicyBinding {
  const SelectionPolicyBinding({
    this.revisionId,
    this.revisionName = selectionPolicyUnadoptedRevision,
    this.preferences = const SelectionPolicyPreferences(),
  });

  /// The revision in force, or `null` when no revision is in force.
  final String? revisionId;

  /// The owner's own name for the revision in force, which is
  /// [selectionPolicyUnadoptedRevision] when there is none.
  final String revisionName;

  final SelectionPolicyPreferences preferences;

  /// Whether an adopted revision is in force and may therefore be revoked.
  bool get hasRevisionInForce => revisionId != null;

  /// Parse the binding as the owner states it, or refuse it.
  ///
  /// A binding the contract cannot read is refused rather than read as
  /// unadopted, because "could not read" is not "nothing is adopted".
  static SelectionPolicyBinding? parse(Object? json) {
    if (json is! Map) return null;
    final revisionId = _boundedText(json['revisionId']);
    if (json['revisionId'] != null && revisionId == null) return null;
    final name = _boundedText(json['revisionName']);
    return SelectionPolicyBinding(
      revisionId: revisionId,
      revisionName: name ?? revisionId ?? selectionPolicyUnadoptedRevision,
      preferences: SelectionPolicyPreferences.parse(json['preferences']),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SelectionPolicyBinding &&
          other.revisionId == revisionId &&
          other.revisionName == revisionName &&
          other.preferences == preferences;

  @override
  int get hashCode => Object.hash(revisionId, revisionName, preferences);

  @override
  String toString() => 'SelectionPolicyBinding($revisionName)';
}

bool _sameList(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
