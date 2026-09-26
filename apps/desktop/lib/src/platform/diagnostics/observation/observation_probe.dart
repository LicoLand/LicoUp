import 'dart:collection';

import 'package:licoup/src/platform/diagnostics/observation/observation_backend.dart';
import 'package:licoup/src/platform/diagnostics/observation/observation_ids.dart';
import 'package:licoup/src/platform/diagnostics/observation/observation_segment.dart';

/// Reads the probe clock, in microseconds.
///
/// The clock is injected so probes stay deterministic under test and so the
/// probe never depends on a wall-clock source it does not own.
typedef ObservationClock = int Function();

/// How many records may be sampled per window.
final class ObservationSamplingBudget {
  const ObservationSamplingBudget({
    required this.maxRecordsPerWindow,
    required this.windowMicroseconds,
  });

  /// No budget: every eligible record is sampled.
  static const ObservationSamplingBudget unlimited = ObservationSamplingBudget(
    maxRecordsPerWindow: 0x7fffffffffffffff,
    windowMicroseconds: 1000000,
  );

  /// Records accepted per window. Zero samples nothing.
  final int maxRecordsPerWindow;

  /// Window length in microseconds; must be positive.
  final int windowMicroseconds;
}

/// Why a record was not queued.
enum ObservationDropReason {
  /// The bounded buffer was full.
  bufferFull('buffer_full'),

  /// The sampling window's record budget was exhausted.
  samplingBudgetExhausted('sampling_budget_exhausted'),

  /// The privacy budget refused the record.
  privacyBudgetExceeded('privacy_budget_exceeded');

  const ObservationDropReason(this.wireName);

  /// The stable wire name of this reason.
  final String wireName;
}

/// What happened to one submitted record.
enum ObservationSubmitOutcome { queued, dropped, disabled }

/// The result of one submission.
final class ObservationSubmitReceipt {
  const ObservationSubmitReceipt(this.outcome, [this.dropReason]);

  /// Accepted into the bounded buffer.
  static const ObservationSubmitReceipt queued = ObservationSubmitReceipt(
    ObservationSubmitOutcome.queued,
  );

  /// The probe is switched off, so there was nothing to record.
  static const ObservationSubmitReceipt disabled = ObservationSubmitReceipt(
    ObservationSubmitOutcome.disabled,
  );

  /// Refused; the reason is counted and the caller proceeds.
  const ObservationSubmitReceipt.dropped(ObservationDropReason reason)
    : this(ObservationSubmitOutcome.dropped, reason);

  /// Which of the three outcomes happened.
  final ObservationSubmitOutcome outcome;

  /// Set only when [outcome] is [ObservationSubmitOutcome.dropped].
  final ObservationDropReason? dropReason;

  @override
  bool operator ==(Object other) =>
      other is ObservationSubmitReceipt &&
      other.outcome == outcome &&
      other.dropReason == dropReason;

  @override
  int get hashCode => Object.hash(outcome, dropReason);

  @override
  String toString() => dropReason == null
      ? 'ObservationSubmitReceipt(${outcome.name})'
      : 'ObservationSubmitReceipt(${outcome.name}, ${dropReason!.wireName})';
}

/// Counted refusals. Every refused record lands in exactly one bucket.
final class ObservationDropCounts {
  const ObservationDropCounts({
    this.bufferFull = 0,
    this.samplingBudgetExhausted = 0,
    this.privacyBudgetExceeded = 0,
    this.lastPrivacyViolation,
  });

  /// Records refused because the bounded buffer was full.
  final int bufferFull;

  /// Records refused because the sampling window was exhausted.
  final int samplingBudgetExhausted;

  /// Records refused by the privacy budget.
  final int privacyBudgetExceeded;

  /// The most recent privacy refusal, named but not valued.
  final ObservationPrivacyViolation? lastPrivacyViolation;

  /// Total counted refusals.
  int get total => bufferFull + samplingBudgetExhausted + privacyBudgetExceeded;

  int reasonCount(ObservationDropReason reason) => switch (reason) {
    ObservationDropReason.bufferFull => bufferFull,
    ObservationDropReason.samplingBudgetExhausted => samplingBudgetExhausted,
    ObservationDropReason.privacyBudgetExceeded => privacyBudgetExceeded,
  };

  @override
  bool operator ==(Object other) =>
      other is ObservationDropCounts &&
      other.bufferFull == bufferFull &&
      other.samplingBudgetExhausted == samplingBudgetExhausted &&
      other.privacyBudgetExceeded == privacyBudgetExceeded &&
      other.lastPrivacyViolation == lastPrivacyViolation;

  @override
  int get hashCode => Object.hash(
    bufferFull,
    samplingBudgetExhausted,
    privacyBudgetExceeded,
    lastPrivacyViolation,
  );

  @override
  String toString() =>
      'ObservationDropCounts(bufferFull: $bufferFull, '
      'samplingBudgetExhausted: $samplingBudgetExhausted, '
      'privacyBudgetExceeded: $privacyBudgetExceeded)';
}

/// Bounded, switchable segment probe.
///
/// `begin` and `submit` are the only methods business code calls. They read no
/// clock while the probe is off, never invoke a backend, and never wait on one:
/// a full buffer refuses the newest record and counts the refusal. Backends run
/// from [drain], which the telemetry owner calls.
///
/// The buffer is bounded by the configured capacity, the sample rate by
/// [ObservationSamplingBudget], and what may be recorded by
/// [ObservationPrivacyBudget]. A refused record always increments exactly one
/// counted reason.
final class ObservationProbe {
  /// A switched-off probe. It reads no clock and holds no buffer, so an off
  /// probe costs business code one null check.
  ObservationProbe.disabled() : _core = null;

  ObservationProbe._(this._core);

  /// A bounded probe with a replaceable backend.
  ///
  /// Throws [ArgumentError] when the buffer capacity or the sampling window is
  /// not positive. Both are configuration errors on the telemetry owner's path,
  /// never on the business path.
  factory ObservationProbe.bounded({
    required int bufferCapacity,
    ObservationSamplingBudget sampling = ObservationSamplingBudget.unlimited,
    ObservationPrivacyBudget privacy = const ObservationPrivacyBudget(),
    required ObservationClock clock,
    required ObservationTelemetryBackend backend,
  }) {
    if (bufferCapacity <= 0) {
      throw ArgumentError.value(
        bufferCapacity,
        'bufferCapacity',
        'must be positive',
      );
    }
    if (sampling.windowMicroseconds <= 0) {
      throw ArgumentError.value(
        sampling.windowMicroseconds,
        'sampling.windowMicroseconds',
        'must be positive',
      );
    }
    return ObservationProbe._(
      _ProbeCore(
        bufferCapacity: bufferCapacity,
        sampling: sampling,
        privacy: privacy,
        clock: clock,
        backend: backend,
      ),
    );
  }

  final _ProbeCore? _core;

  /// Whether this probe records anything.
  bool get isEnabled => _core != null;

  /// Opens a waiting or work segment, or returns null when switched off.
  ///
  /// The clock is read only when the probe is enabled.
  ActiveObservationSegment? begin(ObservationPhase phase, ObservationIds ids) {
    final core = _core;
    if (core == null) return null;
    return ActiveObservationSegment.open(
      phase: phase,
      ids: ids,
      startedMicroseconds: core.clock(),
      clock: core.clock,
    );
  }

  /// Closes a segment and submits it.
  ObservationSubmitReceipt complete(ActiveObservationSegment segment) =>
      submit(segment.finish());

  /// Submits one record. Never blocks on the backend, never fails the caller.
  ObservationSubmitReceipt submit(ObservationSegmentRecord record) {
    final core = _core;
    if (core == null) return ObservationSubmitReceipt.disabled;
    final violation =
        core.privacy.firstViolation(record.ids) ??
        (record.links.length > core.privacy.maxLinks
            ? const ObservationPrivacyViolation.tooManyLinks()
            : null);
    if (violation != null) {
      core.refuse(ObservationDropReason.privacyBudgetExceeded, violation);
      return const ObservationSubmitReceipt.dropped(
        ObservationDropReason.privacyBudgetExceeded,
      );
    }
    core.advanceWindow(core.clock());
    if (core.sampledInWindow >= core.sampling.maxRecordsPerWindow) {
      core.refuse(ObservationDropReason.samplingBudgetExhausted, null);
      return const ObservationSubmitReceipt.dropped(
        ObservationDropReason.samplingBudgetExhausted,
      );
    }
    if (core.buffer.length >= core.bufferCapacity) {
      core.refuse(ObservationDropReason.bufferFull, null);
      return const ObservationSubmitReceipt.dropped(
        ObservationDropReason.bufferFull,
      );
    }
    core.accept(record);
    return ObservationSubmitReceipt.queued;
  }

  /// Hands at most [maxRecords] queued records to the backend and returns how
  /// many were emitted.
  ///
  /// Records leave the buffer before the backend runs, so a backend that
  /// submits re-entrantly cannot corrupt or stall the drain.
  int drain({int maxRecords = 64}) {
    final core = _core;
    if (core == null) return 0;
    final batch = core.takeBatch(maxRecords);
    for (final record in batch) {
      core.backend.emit(record);
    }
    return batch.length;
  }

  /// Queued records not yet drained.
  int get pendingCount => _core?.buffer.length ?? 0;

  /// Counted refusals so far.
  ObservationDropCounts get dropCounts =>
      _core?.dropCounts ?? const ObservationDropCounts();
}

final class _ProbeCore {
  _ProbeCore({
    required this.bufferCapacity,
    required this.sampling,
    required this.privacy,
    required this.clock,
    required this.backend,
  });

  final int bufferCapacity;
  final ObservationSamplingBudget sampling;
  final ObservationPrivacyBudget privacy;
  final ObservationClock clock;
  final ObservationTelemetryBackend backend;

  final ListQueue<ObservationSegmentRecord> buffer =
      ListQueue<ObservationSegmentRecord>();
  int sampledInWindow = 0;
  int? windowOpenedMicroseconds;
  final Map<ObservationDropReason, int> _drops = <ObservationDropReason, int>{};
  ObservationPrivacyViolation? _lastPrivacyViolation;

  ObservationDropCounts get dropCounts => ObservationDropCounts(
    bufferFull: _drops[ObservationDropReason.bufferFull] ?? 0,
    samplingBudgetExhausted:
        _drops[ObservationDropReason.samplingBudgetExhausted] ?? 0,
    privacyBudgetExceeded:
        _drops[ObservationDropReason.privacyBudgetExceeded] ?? 0,
    lastPrivacyViolation: _lastPrivacyViolation,
  );

  void advanceWindow(int nowMicroseconds) {
    final opened = windowOpenedMicroseconds;
    if (opened == null ||
        nowMicroseconds - opened >= sampling.windowMicroseconds) {
      windowOpenedMicroseconds = nowMicroseconds;
      sampledInWindow = 0;
    }
  }

  void accept(ObservationSegmentRecord record) {
    sampledInWindow += 1;
    buffer.addLast(record);
  }

  void refuse(
    ObservationDropReason reason,
    ObservationPrivacyViolation? violation,
  ) {
    _drops.update(reason, (count) => count + 1, ifAbsent: () => 1);
    if (violation != null) {
      _lastPrivacyViolation = violation;
    }
  }

  List<ObservationSegmentRecord> takeBatch(int maxRecords) {
    final batch = <ObservationSegmentRecord>[];
    while (batch.length < maxRecords && buffer.isNotEmpty) {
      batch.add(buffer.removeFirst());
    }
    return batch;
  }
}
