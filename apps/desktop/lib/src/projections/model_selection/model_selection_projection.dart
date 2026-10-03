import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/contracts/model_selection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

/// The code reported when the native document could not be read at all.
const String modelSelectionUnavailableNoticeCode =
    'model_selection_unavailable';

/// Human-readable labels for the state codes this surface renders.
///
/// The projection carries labels because it is the renderer-facing contract,
/// and it keeps the state code beside every label so a renderer never has to
/// infer a dimension from the text.
final class ModelSelectionLabels {
  const ModelSelectionLabels._();

  static const String supportSupported = 'Supported';
  static const String supportUnsupported = 'Not supported';
  static const String supportUnknown = 'Support unknown';

  static const String availabilityObserved = 'Observed';
  static const String availabilityUnobserved = 'Not observed';

  static const String credentialPresent = 'Credential present';
  static const String credentialAbsent = 'No credential';
  static const String credentialUnknown = 'Credential unknown';

  static const String scopeAllowed = 'Can run';
  static const String scopeBlocked = 'Blocked';
  static const String scopeUndetermined = 'Undetermined';

  static String support(String state) => switch (state) {
    ModelSelectionSupportState.supported => supportSupported,
    ModelSelectionSupportState.unsupported => supportUnsupported,
    _ => supportUnknown,
  };

  static String availability(String state) =>
      state == ModelSelectionAvailabilityState.observed
      ? availabilityObserved
      : availabilityUnobserved;

  static String credentials(String state) => switch (state) {
    ModelSelectionCredentialState.present => credentialPresent,
    ModelSelectionCredentialState.absent => credentialAbsent,
    _ => credentialUnknown,
  };

  static String scope(String state) => switch (state) {
    ModelSelectionScopeState.allowed => scopeAllowed,
    ModelSelectionScopeState.blocked => scopeBlocked,
    _ => scopeUndetermined,
  };

  /// The label for a turn kind the project surface names. Both scopes resolve
  /// through the same map so a renderer cannot show one scope's outcome under
  /// the other's heading.
  static String scopeName(String scope) => switch (scope) {
    'direct' => 'Direct',
    'workflow' => 'Workflow',
    _ => scope,
  };
}

/// One scope's outcome, as a renderer needs it: the scope it belongs to, its
/// state, its label and the reason code behind it.
final class ModelSelectionOutcomeView {
  const ModelSelectionOutcomeView({
    required this.scope,
    required this.scopeLabel,
    required this.state,
    required this.label,
    required this.reason,
    required this.executes,
  });

  final String scope;
  final String scopeLabel;
  final String state;
  final String label;
  final String reason;

  /// Only a stated `allowed` sets this. `blocked` and `undetermined` both stay
  /// `false` without being the same fact, which the label and state keep apart.
  final bool executes;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ModelSelectionOutcomeView &&
          other.scope == scope &&
          other.scopeLabel == scopeLabel &&
          other.state == state &&
          other.label == label &&
          other.reason == reason &&
          other.executes == executes;

  @override
  int get hashCode =>
      Object.hash(scope, scopeLabel, state, label, reason, executes);

  @override
  String toString() =>
      'ModelSelectionOutcomeView($scope, $state, $label, $reason)';
}

/// One model of one Agent, every dimension labelled separately.
final class ModelSelectionViewItem {
  const ModelSelectionViewItem({
    required this.agent,
    required this.model,
    required this.canonicalId,
    required this.displayName,
    required this.evidence,
    required this.supportState,
    required this.supportLabel,
    required this.supportReason,
    required this.availabilityState,
    required this.availabilityLabel,
    required this.availabilityReason,
    required this.observedAtUnixMs,
    required this.credentialState,
    required this.credentialLabel,
    required this.credentialReason,
    required this.providers,
    required this.outcomes,
  });

  final String agent;
  final String model;
  final String? canonicalId;
  final String displayName;
  final String evidence;
  final String supportState;
  final String supportLabel;
  final String supportReason;
  final String availabilityState;
  final String availabilityLabel;
  final String availabilityReason;
  final int? observedAtUnixMs;
  final String credentialState;
  final String credentialLabel;
  final String credentialReason;
  final List<String> providers;
  final List<ModelSelectionOutcomeView> outcomes;

  /// The outcome for one scope, or `null` when the projection recorded none.
  ModelSelectionOutcomeView? outcomeFor(String scope) {
    for (final outcome in outcomes) {
      if (outcome.scope == scope) return outcome;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ModelSelectionViewItem &&
          other.agent == agent &&
          other.model == model &&
          other.canonicalId == canonicalId &&
          other.displayName == displayName &&
          other.evidence == evidence &&
          other.supportState == supportState &&
          other.supportLabel == supportLabel &&
          other.supportReason == supportReason &&
          other.availabilityState == availabilityState &&
          other.availabilityLabel == availabilityLabel &&
          other.availabilityReason == availabilityReason &&
          other.observedAtUnixMs == observedAtUnixMs &&
          other.credentialState == credentialState &&
          other.credentialLabel == credentialLabel &&
          other.credentialReason == credentialReason &&
          _sameList(other.providers, providers) &&
          _sameList(other.outcomes, outcomes);

  @override
  int get hashCode => Object.hash(
    agent,
    model,
    canonicalId,
    displayName,
    evidence,
    supportState,
    supportLabel,
    supportReason,
    availabilityState,
    availabilityLabel,
    availabilityReason,
    observedAtUnixMs,
    credentialState,
    credentialLabel,
    credentialReason,
    Object.hashAll(providers),
    Object.hashAll(outcomes),
  );

  @override
  String toString() =>
      'ModelSelectionViewItem($agent, $model, support=$supportLabel, '
      'availability=$availabilityLabel, credentials=$credentialLabel, '
      'outcomes=$outcomes)';
}

/// The renderable selection matrix for one Agent.
///
/// It is a projection, not a second source of truth: it reads the parsed
/// contract and adds the labels and scope order a renderer needs. The `targets`
/// and `models` surfaces keep their own projections; this one is not a
/// replacement for the readiness a target card shows, and it never computes an
/// outcome of its own.
final class ModelSelectionProjection {
  ModelSelectionProjection({
    required this.agent,
    required Iterable<ModelSelectionViewItem> entries,
    required this.phase,
    this.generation,
    this.observedAtUnixMs = 0,
    this.notice,
  }) : entries = immutablePresentationList(entries);

  final String agent;
  final String? generation;
  final int observedAtUnixMs;
  final List<ModelSelectionViewItem> entries;
  final PresentationPhase phase;
  final PresentationNotice? notice;

  /// Build the projection from one native document.
  ///
  /// A document the contract refuses — absent, malformed, or another revision —
  /// produces a failed projection with an explicit reason instead of an empty
  /// successful one, so "could not read" is never rendered as "nothing there".
  factory ModelSelectionProjection.fromDocument(
    Object? document, {
    required String agent,
  }) {
    final matrix = ModelSelectionMatrix.parse(document);
    if (matrix == null) {
      return ModelSelectionProjection(
        agent: agent,
        entries: const [],
        phase: PresentationPhase.failed,
        notice: const PresentationNotice(
          id: 'model-selection-unavailable',
          title: 'Model selection',
          message: 'The selection facts for this Agent could not be read.',
          severity: PresentationNoticeSeverity.error,
          reasonCode: modelSelectionUnavailableNoticeCode,
        ),
      );
    }
    return ModelSelectionProjection(
      agent: matrix.agent.trim().isEmpty ? agent : matrix.agent,
      generation: matrix.generation,
      observedAtUnixMs: matrix.observedAtUnixMs,
      entries: matrix.entries.map(_viewItem).toList(growable: false),
      phase: PresentationPhase.ready,
    );
  }

  /// Whether any entry states that this Agent can run in one scope right now.
  bool executesIn(String scope) =>
      entries.any((entry) => entry.outcomeFor(scope)?.executes ?? false);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ModelSelectionProjection &&
          other.agent == agent &&
          other.generation == generation &&
          other.observedAtUnixMs == observedAtUnixMs &&
          samePresentationList(other.entries, entries) &&
          other.phase == phase &&
          other.notice == notice;

  @override
  int get hashCode => Object.hash(
    agent,
    generation,
    observedAtUnixMs,
    Object.hashAll(entries),
    phase,
    notice,
  );

  @override
  String toString() =>
      'ModelSelectionProjection($agent, entries=${entries.length}, $phase)';
}

ModelSelectionViewItem _viewItem(ModelSelectionEntry entry) {
  return ModelSelectionViewItem(
    agent: entry.agent,
    model: entry.model,
    canonicalId: entry.canonicalId,
    displayName: (entry.canonicalDisplayName ?? '').trim().isEmpty
        ? entry.model
        : entry.canonicalDisplayName!,
    evidence: entry.evidence,
    supportState: entry.support.state,
    supportLabel: ModelSelectionLabels.support(entry.support.state),
    supportReason: entry.support.reason,
    availabilityState: entry.availability.state,
    availabilityLabel: ModelSelectionLabels.availability(
      entry.availability.state,
    ),
    availabilityReason: entry.availability.reason,
    observedAtUnixMs: entry.availability.observedAtUnixMs,
    credentialState: entry.credentials.state,
    credentialLabel: ModelSelectionLabels.credentials(entry.credentials.state),
    credentialReason: entry.credentials.reason,
    providers: entry.providers,
    outcomes: [
      for (final outcome in entry.scopeOutcomes)
        ModelSelectionOutcomeView(
          scope: outcome.scope,
          scopeLabel: ModelSelectionLabels.scopeName(outcome.scope),
          state: outcome.state,
          label: ModelSelectionLabels.scope(outcome.state),
          reason: outcome.reason,
          executes: outcome.isAllowed,
        ),
    ],
  );
}

bool _sameList<T>(List<T> left, List<T> right) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
