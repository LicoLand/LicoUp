/// The desktop side of the selection matrix: one Agent's support, availability,
/// credential and per-scope execution facts, kept apart.
///
/// This file parses the document `licoup-model-catalog` renders
/// (`selection_matrix_document`, documented by
/// `schemas/client_bridge/model_selection.json`). It deliberately exposes
/// **four** dimension records rather than one status string: a client that wants
/// to show readiness has to name which dimension it means, and a client that
/// wants to show whether the Agent can run now has to name which scope.
///
/// Every value is bounded and defensively parsed. A reason code that is empty,
/// over-long or control-bearing becomes the explicit `unavailable` code, so a
/// malformed field can never silently read as a positive state.
library;

/// The document revision this contract parses. A document that states another
/// revision is refused rather than interpreted.
const int modelSelectionSchemaVersion = 1;

/// The two request scopes this contract always reports, in render order.
const List<String> modelSelectionScopes = ['direct', 'workflow'];

/// Whether an Agent/provider/model combination is usable at all.
class ModelSelectionSupportState {
  static const String supported = 'supported';
  static const String unsupported = 'unsupported';
  static const String unknown = 'unknown';
}

/// Whether a live source on this machine reported the model.
class ModelSelectionAvailabilityState {
  static const String observed = 'observed';
  static const String unobserved = 'unobserved';
}

/// Whether this host holds a usable credential for the serving provider.
class ModelSelectionCredentialState {
  static const String present = 'present';
  static const String absent = 'absent';
  static const String unknown = 'unknown';
}

/// Whether the effective policy admits this Agent for one scope right now.
class ModelSelectionScopeState {
  static const String allowed = 'allowed';
  static const String blocked = 'blocked';
  static const String undetermined = 'undetermined';
}

/// The code reported when a field could not be read as stated.
const String modelSelectionUnavailableCode = 'selection_fact_unavailable';

/// The code reported when a scope carried no outcome at all.
const String modelSelectionScopeNotRecordedReason =
    'scope_outcome_not_recorded';

/// The code reported when an Agent is not declared on this host.
const String modelSelectionAgentNotDeclaredReason =
    'agent_not_declared_on_host';

/// The code reported when no effective policy owner is composed.
const String modelSelectionPolicyOwnerAbsentReason =
    'selection_policy_owner_absent';

int _int(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

int? _nullableNonNegativeInt(Object? value) {
  if (value == null) return null;
  final parsed = _int(value);
  return parsed < 0 ? null : parsed;
}

String? _optionalCode(Object? value, {int maxLength = 256}) {
  final text = value?.toString().trim() ?? '';
  if (text.isEmpty || text.length > maxLength) return null;
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:@+\-]{0,255}$').hasMatch(text)) {
    return null;
  }
  return text;
}

String _reason(Object? value) =>
    _optionalCode(value) ?? modelSelectionUnavailableCode;

/// One dimension: its state code and the reason the state holds.
class ModelSelectionDimension {
  const ModelSelectionDimension({required this.state, required this.reason});

  final String state;
  final String reason;

  factory ModelSelectionDimension.fromJson(
    Object? json, {
    required Set<String> knownStates,
    required String unknownState,
  }) {
    final map = json is Map ? json : const {};
    final parsed = _optionalCode(map['state']);
    return ModelSelectionDimension(
      state: parsed != null && knownStates.contains(parsed)
          ? parsed
          : unknownState,
      reason: _reason(map['reason']),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ModelSelectionDimension &&
          other.state == state &&
          other.reason == reason;

  @override
  int get hashCode => Object.hash(state, reason);

  @override
  String toString() => 'ModelSelectionDimension($state, $reason)';
}

/// Availability carries the observation time on the dimension itself: an
/// observed model without a time is not the same fact as an observed one with
/// one, and neither is ever inferred from the other dimension.
class ModelSelectionAvailability {
  const ModelSelectionAvailability({
    required this.state,
    required this.reason,
    this.observedAtUnixMs,
  });

  final String state;
  final String reason;
  final int? observedAtUnixMs;

  bool get isObserved =>
      state == ModelSelectionAvailabilityState.observed &&
      observedAtUnixMs != null;

  factory ModelSelectionAvailability.fromJson(Object? json) {
    final map = json is Map ? json : const {};
    final parsed = _optionalCode(map['state']);
    final known = const {
      ModelSelectionAvailabilityState.observed,
      ModelSelectionAvailabilityState.unobserved,
    };
    final state = parsed != null && known.contains(parsed)
        ? parsed
        : ModelSelectionAvailabilityState.unobserved;
    final observedAt = _nullableNonNegativeInt(map['observedAtUnixMs']);
    return ModelSelectionAvailability(
      state: state,
      reason: _reason(map['reason']),
      observedAtUnixMs: state == ModelSelectionAvailabilityState.observed
          ? observedAt
          : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ModelSelectionAvailability &&
          other.state == state &&
          other.reason == reason &&
          other.observedAtUnixMs == observedAtUnixMs;

  @override
  int get hashCode => Object.hash(state, reason, observedAtUnixMs);

  @override
  String toString() =>
      'ModelSelectionAvailability($state, $reason, $observedAtUnixMs)';
}

/// One Agent's outcome for one scope, with the scope recorded on the outcome.
class ModelSelectionScopeOutcome {
  const ModelSelectionScopeOutcome({
    required this.scope,
    required this.state,
    required this.reason,
  });

  final String scope;
  final String state;
  final String reason;

  bool get isAllowed => state == ModelSelectionScopeState.allowed;

  factory ModelSelectionScopeOutcome.fromJson(Object? json) {
    final map = json is Map ? json : const {};
    final scope = _optionalCode(map['scope']);
    final parsed = _optionalCode(map['state']);
    final known = const {
      ModelSelectionScopeState.allowed,
      ModelSelectionScopeState.blocked,
      ModelSelectionScopeState.undetermined,
    };
    return ModelSelectionScopeOutcome(
      scope: scope ?? '',
      state: parsed != null && known.contains(parsed)
          ? parsed
          : ModelSelectionScopeState.undetermined,
      reason: _reason(map['reason']),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ModelSelectionScopeOutcome &&
          other.scope == scope &&
          other.state == state &&
          other.reason == reason;

  @override
  int get hashCode => Object.hash(scope, state, reason);

  @override
  String toString() => 'ModelSelectionScopeOutcome($scope, $state, $reason)';
}

/// One model of one Agent, every dimension kept apart.
class ModelSelectionEntry {
  const ModelSelectionEntry({
    required this.agent,
    required this.model,
    required this.canonicalId,
    required this.canonicalDisplayName,
    required this.evidence,
    required this.support,
    required this.availability,
    required this.credentials,
    required this.providers,
    required this.scopeOutcomes,
  });

  final String agent;
  final String model;
  final String? canonicalId;
  final String? canonicalDisplayName;

  /// Which catalogue state the name is in: `declaredOnly`, `observed`, or
  /// `unknown`.
  final String evidence;
  final ModelSelectionDimension support;
  final ModelSelectionAvailability availability;
  final ModelSelectionDimension credentials;
  final List<String> providers;
  final List<ModelSelectionScopeOutcome> scopeOutcomes;

  /// The outcome recorded for one scope, or `null` when the document did not
  /// state one. A missing scope is not an allowed scope.
  ModelSelectionScopeOutcome? outcomeFor(String scope) {
    for (final outcome in scopeOutcomes) {
      if (outcome.scope == scope) return outcome;
    }
    return null;
  }

  /// Whether the effective policy admits this Agent for one scope. Only a
  /// stated `allowed` answers `true`.
  bool executes(String scope) => outcomeFor(scope)?.isAllowed ?? false;

  factory ModelSelectionEntry.fromJson(Object? json) {
    final map = json is Map ? json : const {};
    final providers = <String>[];
    final rawProviders = map['providers'];
    if (rawProviders is List) {
      for (final provider in rawProviders) {
        final code = _optionalCode(provider);
        if (code != null) providers.add(code);
      }
    }
    final outcomes = <ModelSelectionScopeOutcome>[];
    final rawOutcomes = map['scopes'];
    if (rawOutcomes is List) {
      for (final outcome in rawOutcomes) {
        outcomes.add(ModelSelectionScopeOutcome.fromJson(outcome));
      }
    }
    // Every scope this contract renders is present exactly once: a scope the
    // document omitted is stated as not recorded rather than left to a caller
    // to default.
    final complete = <ModelSelectionScopeOutcome>[
      for (final scope in modelSelectionScopes)
        outcomes.firstWhere(
          (outcome) => outcome.scope == scope,
          orElse: () => ModelSelectionScopeOutcome(
            scope: scope,
            state: ModelSelectionScopeState.undetermined,
            reason: modelSelectionScopeNotRecordedReason,
          ),
        ),
    ];
    return ModelSelectionEntry(
      agent: _optionalCode(map['agent']) ?? '',
      model: _optionalCode(map['model']) ?? '',
      canonicalId: _optionalCode(map['canonicalId'], maxLength: 512),
      canonicalDisplayName: _optionalCode(
        map['canonicalDisplayName'],
        maxLength: 512,
      ),
      evidence: _optionalCode(map['evidence']) ?? 'unknown',
      support: ModelSelectionDimension.fromJson(
        map['support'],
        knownStates: const {
          ModelSelectionSupportState.supported,
          ModelSelectionSupportState.unsupported,
          ModelSelectionSupportState.unknown,
        },
        unknownState: ModelSelectionSupportState.unknown,
      ),
      availability: ModelSelectionAvailability.fromJson(map['availability']),
      credentials: ModelSelectionDimension.fromJson(
        map['credentials'],
        knownStates: const {
          ModelSelectionCredentialState.present,
          ModelSelectionCredentialState.absent,
          ModelSelectionCredentialState.unknown,
        },
        unknownState: ModelSelectionCredentialState.unknown,
      ),
      providers: List.unmodifiable(providers),
      scopeOutcomes: List.unmodifiable(complete),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ModelSelectionEntry &&
          other.agent == agent &&
          other.model == model &&
          other.canonicalId == canonicalId &&
          other.canonicalDisplayName == canonicalDisplayName &&
          other.evidence == evidence &&
          other.support == support &&
          other.availability == availability &&
          other.credentials == credentials &&
          _sameList(other.providers, providers) &&
          _sameList(other.scopeOutcomes, scopeOutcomes);

  @override
  int get hashCode => Object.hash(
    agent,
    model,
    canonicalId,
    canonicalDisplayName,
    evidence,
    support,
    availability,
    credentials,
    Object.hashAll(providers),
    Object.hashAll(scopeOutcomes),
  );

  @override
  String toString() =>
      'ModelSelectionEntry($agent, $model, support=${support.state}, '
      'availability=${availability.state}, credentials=${credentials.state}, '
      'scopes=$scopeOutcomes)';
}

/// One Agent's complete selection matrix document.
class ModelSelectionMatrix {
  const ModelSelectionMatrix({
    required this.agent,
    required this.generation,
    required this.observedAtUnixMs,
    required this.entries,
  });

  final String agent;
  final String? generation;
  final int observedAtUnixMs;
  final List<ModelSelectionEntry> entries;

  /// Parse one native document.
  ///
  /// The answer is `null` when the document is missing, is not an object, or
  /// states another revision: a caller that receives `null` reports
  /// unavailable facts instead of interpreting a shape it does not know.
  static ModelSelectionMatrix? parse(Object? json) {
    if (json is! Map) return null;
    if (_int(json['schemaVersion']) != modelSelectionSchemaVersion) return null;
    final rawEntries = json['entries'];
    if (rawEntries is! List) return null;
    return ModelSelectionMatrix(
      agent: _optionalCode(json['agent']) ?? '',
      generation: _optionalCode(json['generation'], maxLength: 256),
      observedAtUnixMs: _int(json['observedAtUnixMs']),
      entries: List.unmodifiable(rawEntries.map(ModelSelectionEntry.fromJson)),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ModelSelectionMatrix &&
          other.agent == agent &&
          other.generation == generation &&
          other.observedAtUnixMs == observedAtUnixMs &&
          _sameList(other.entries, entries);

  @override
  int get hashCode =>
      Object.hash(agent, generation, observedAtUnixMs, Object.hashAll(entries));

  @override
  String toString() =>
      'ModelSelectionMatrix($agent, entries=${entries.length})';
}

bool _sameList<T>(List<T> left, List<T> right) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
