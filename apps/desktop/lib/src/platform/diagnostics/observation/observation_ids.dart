import 'package:presentation_contract/presentation_contract.dart';

/// One named correlation slot of the v7 observation port (contract C07).
enum ObservationIdField {
  userInteractionId('userInteractionId'),
  requestId('requestId'),
  conversationId('conversationId'),
  runId('runId'),
  nodeVisit('nodeVisit'),
  effectId('effectId'),
  attemptToken('attemptToken'),
  noticeId('noticeId'),
  sourcePosition('sourcePosition'),
  prepareId('prepareId');

  const ObservationIdField(this.wireName);

  /// The contract's field name; never localised.
  final String wireName;
}

/// Correlation ids attached to one observation segment.
///
/// Values are opaque and are never reinterpreted here. Every slot is optional
/// because a segment may sit between causal hops: absent is honest, and a
/// placeholder value is not.
///
/// These ids are high-cardinality trace data. They ride on
/// [ObservationSegmentRecord] and the telemetry backend, and no metric surface
/// accepts them.
final class ObservationIds {
  const ObservationIds({
    this.userInteractionId,
    this.requestId,
    this.conversationId,
    this.runId,
    this.nodeVisit,
    this.effectId,
    this.attemptToken,
    this.noticeId,
    this.sourcePosition,
    this.prepareId,
  });

  /// Adopts the causal id the renderer already carries.
  ///
  /// `TraceContext` is the existing carrier across presentation operations and
  /// holds exactly one opaque string, so only the request id round-trips. The
  /// remaining slots stay segment-local: inventing a second cross-plane carrier
  /// is what the plan forbids.
  factory ObservationIds.fromTraceContext(TraceContext? trace) {
    final traceId = trace?.traceId;
    if (traceId == null || traceId.isEmpty) return none;
    return ObservationIds(requestId: traceId);
  }

  /// No correlation id is known.
  static const ObservationIds none = ObservationIds();

  final String? userInteractionId;
  final String? requestId;
  final String? conversationId;
  final String? runId;
  final String? nodeVisit;
  final String? effectId;
  final String? attemptToken;
  final String? noticeId;
  final String? sourcePosition;
  final String? prepareId;

  /// Reads one slot.
  String? operator [](ObservationIdField field) => switch (field) {
    ObservationIdField.userInteractionId => userInteractionId,
    ObservationIdField.requestId => requestId,
    ObservationIdField.conversationId => conversationId,
    ObservationIdField.runId => runId,
    ObservationIdField.nodeVisit => nodeVisit,
    ObservationIdField.effectId => effectId,
    ObservationIdField.attemptToken => attemptToken,
    ObservationIdField.noticeId => noticeId,
    ObservationIdField.sourcePosition => sourcePosition,
    ObservationIdField.prepareId => prepareId,
  };

  /// Writes one slot, replacing any previous value.
  ObservationIds withId(ObservationIdField field, String value) =>
      ObservationIds(
        userInteractionId: field == ObservationIdField.userInteractionId
            ? value
            : userInteractionId,
        requestId: field == ObservationIdField.requestId ? value : requestId,
        conversationId: field == ObservationIdField.conversationId
            ? value
            : conversationId,
        runId: field == ObservationIdField.runId ? value : runId,
        nodeVisit: field == ObservationIdField.nodeVisit ? value : nodeVisit,
        effectId: field == ObservationIdField.effectId ? value : effectId,
        attemptToken: field == ObservationIdField.attemptToken
            ? value
            : attemptToken,
        noticeId: field == ObservationIdField.noticeId ? value : noticeId,
        sourcePosition: field == ObservationIdField.sourcePosition
            ? value
            : sourcePosition,
        prepareId: field == ObservationIdField.prepareId ? value : prepareId,
      );

  /// True when no slot is populated.
  bool get isEmpty => entries.isEmpty;

  /// True when at least one slot is populated.
  bool get isNotEmpty => !isEmpty;

  /// Populated slots in contract order.
  Iterable<MapEntry<ObservationIdField, String>> get entries sync* {
    for (final field in ObservationIdField.values) {
      final value = this[field];
      if (value != null) {
        yield MapEntry<ObservationIdField, String>(field, value);
      }
    }
  }

  /// The wire shape; absent slots stay absent.
  Map<String, String> toJson() => <String, String>{
    for (final entry in entries) entry.key.wireName: entry.value,
  };

  /// Hands this context to the existing renderer carrier.
  TraceContext toTraceContext() =>
      TraceContext(traceId: requestId ?? userInteractionId);

  @override
  bool operator ==(Object other) =>
      other is ObservationIds &&
      other.userInteractionId == userInteractionId &&
      other.requestId == requestId &&
      other.conversationId == conversationId &&
      other.runId == runId &&
      other.nodeVisit == nodeVisit &&
      other.effectId == effectId &&
      other.attemptToken == attemptToken &&
      other.noticeId == noticeId &&
      other.sourcePosition == sourcePosition &&
      other.prepareId == prepareId;

  @override
  int get hashCode => Object.hash(
    userInteractionId,
    requestId,
    conversationId,
    runId,
    nodeVisit,
    effectId,
    attemptToken,
    noticeId,
    sourcePosition,
    prepareId,
  );

  /// Renders populated ids as `field=value` pairs for a trace line.
  @override
  String toString() => isEmpty
      ? '-'
      : entries
            .map((entry) => '${entry.key.wireName}=${entry.value}')
            .join(' ');
}

/// Why one correlation id value was refused.
enum ObservationPrivacyViolationKind {
  /// Empty, or longer than [ObservationPrivacyBudget.maxIdBytes].
  oversized('oversized'),

  /// Contains a character outside printable ASCII, so it cannot be an opaque
  /// id. This is what rejects transcripts, newline-bearing text, and
  /// environment dumps.
  unprintable('unprintable'),

  /// Looks like an absolute, home-anchored, drive-qualified, or UNC path, so it
  /// would disclose a private filesystem location.
  privatePath('private_path');

  const ObservationPrivacyViolationKind(this.wireName);

  /// The stable wire name of this reason.
  final String wireName;
}

/// One refused value. The offending value itself is never retained.
final class ObservationPrivacyViolation {
  const ObservationPrivacyViolation.id(this.field, this.kind);

  const ObservationPrivacyViolation.tooManyLinks() : field = null, kind = null;

  /// The refused correlation slot, when the violation names one.
  final ObservationIdField? field;

  /// The refusal reason, when the violation names one.
  final ObservationPrivacyViolationKind? kind;

  @override
  bool operator ==(Object other) =>
      other is ObservationPrivacyViolation &&
      other.field == field &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(field, kind);

  @override
  String toString() => switch ((field, kind)) {
    (
      final ObservationIdField named,
      final ObservationPrivacyViolationKind why,
    ) =>
      'ObservationPrivacyViolation(${named.wireName}, ${why.wireName})',
    _ => 'ObservationPrivacyViolation(tooManyLinks)',
  };
}

/// Bounds the observation port accepts before refusing a record.
final class ObservationPrivacyBudget {
  const ObservationPrivacyBudget({this.maxIdBytes = 128, this.maxLinks = 8});

  /// Longest accepted correlation id, in bytes.
  final int maxIdBytes;

  /// Most span links one segment may carry.
  final int maxLinks;

  /// Validates one correlation id value without retaining it.
  ObservationPrivacyViolationKind? idViolation(String value) {
    if (value.isEmpty || value.length > maxIdBytes) {
      return ObservationPrivacyViolationKind.oversized;
    }
    if (!value.codeUnits.every((unit) => unit >= 0x21 && unit <= 0x7e)) {
      return ObservationPrivacyViolationKind.unprintable;
    }
    if (looksLikePrivatePath(value)) {
      return ObservationPrivacyViolationKind.privatePath;
    }
    return null;
  }

  /// Returns the first correlation slot this budget refuses.
  ObservationPrivacyViolation? firstViolation(ObservationIds ids) {
    for (final entry in ids.entries) {
      final kind = idViolation(entry.value);
      if (kind != null) {
        return ObservationPrivacyViolation.id(entry.key, kind);
      }
    }
    return null;
  }
}

/// True when the value discloses a private filesystem location.
///
/// Repository-relative positions such as `lib/src/a.dart:12` stay acceptable;
/// only absolute, home-anchored, drive-qualified, and UNC forms are refused.
bool looksLikePrivatePath(String value) {
  if (value.startsWith('/') ||
      value.startsWith('~') ||
      value.startsWith(r'\\')) {
    return true;
  }
  return value.length >= 3 &&
      value[1] == ':' &&
      (value[2] == '\\' || value[2] == '/');
}
