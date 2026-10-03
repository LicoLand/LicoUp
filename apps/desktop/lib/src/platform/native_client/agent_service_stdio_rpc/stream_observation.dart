import 'dart:collection';

/// Bounded, backend-optional observation of the native stdio stream phases.
///
/// The port is the only place transport phase facts may be recorded. It writes
/// nothing, opens no second store and keeps no record at all until a
/// [StreamObservationBackend] is installed: without an installed backend every
/// submission is refused with [StreamObservationRefusal.noBackend] instead of
/// being buffered, so an unobserved transport is byte-for-byte the transport
/// that existed before this port.
///
/// An installed backend receives only admitted records. Admission is bounded in
/// one direction and refused in another:
///
/// * a record classified as identifying, carrying an over-long correlation
///   identity, or measuring more than the record size bound is refused with a
///   typed reason and is never truncated into an admissible record;
/// * admitted records are retained in the port's single bounded window, which
///   drops its oldest record when the record or byte bound is reached, so the
///   window can never grow with the stream.
///
/// Phase facts stay aggregate transport facts: a phase, a lane, bounded sizes
/// and an opaque bounded correlation identity. Message text, payloads, file
/// paths and Agent content are not representable here, and the port never
/// attaches a record to a native or network request.

/// The transport phases a record can describe.
enum StreamObservationPhase {
  /// Bytes accepted from the native stdout stream.
  acquisition,

  /// One framed payload decoded to an envelope, inline or off-isolate.
  decode,

  /// One decoded frame handed to the consumer waiting for it. Dispatching the
  /// reply of a control request is that control attempt's settlement.
  dispatch,

  /// One request expectation installed on the session before its frame is
  /// written. Installing a control expectation is the control lane's attempt.
  install,

  /// The framed decode backlog released: it drained to empty, or backpressure
  /// resumed the stdout stream below its resume watermark.
  drain,
}

/// The transport lane a record belongs to.
enum StreamObservationLane {
  /// Ordinary replies, dispatched in wire order.
  ordered,

  /// Single-shot control replies (cancel, steer, detach).
  control,
}

/// How far a record may travel from the process that produced it.
enum StreamObservationPrivacy {
  /// Transport facts only: phase, lane, sizes and an opaque bounded
  /// correlation token. No payload, path or user value is carried.
  aggregate,

  /// A record whose value could identify a person, path, prompt or payload.
  /// The port refuses it, so observation never becomes content capture.
  identifying,
}

/// Why the port refused a record. A refusal is a returned value; the refused
/// record is never retained and never reaches an installed backend.
enum StreamObservationRefusal {
  /// No backend is installed. The port fails closed instead of buffering.
  noBackend,

  /// The record was classified as [StreamObservationPrivacy.identifying].
  identifyingRecord,

  /// The measured unit exceeds the record size bound.
  oversizedRecord,

  /// The correlation identity exceeds its character bound.
  oversizedCorrelation,
}

/// One admitted transport phase fact.
///
/// Records are created by [StreamObservationPort.observe] only after every
/// admission rule passed, so a refused submission never exists as a record.
final class StreamObservationRecord {
  const StreamObservationRecord({
    required this.phase,
    required this.lane,
    required this.privacy,
    required this.correlationId,
    required this.sizeBytes,
    required this.backlogBytes,
  });

  final StreamObservationPhase phase;
  final StreamObservationLane lane;
  final StreamObservationPrivacy privacy;

  /// Bounded opaque request identity, or empty when the phase has no request.
  final String correlationId;

  /// Measured bytes of the observed unit, or zero when the phase has none.
  final int sizeBytes;

  /// Framed decode backlog in bytes after the phase, or zero when unrelated.
  final int backlogBytes;
}

/// The installed owner that receives admitted records.
///
/// A backend is notified once per admitted record, in admission order. The port
/// isolates backend failures: an observation callback can never fail the
/// transport it observes.
abstract interface class StreamObservationBackend {
  void acceptStreamObservation(StreamObservationRecord record);
}

/// The typed result of one observation submission.
sealed class StreamObservationAdmission {
  const StreamObservationAdmission();
}

/// The record was admitted into the bounded window and delivered.
final class StreamObservationAdmitted extends StreamObservationAdmission {
  const StreamObservationAdmitted({
    required this.retainedCount,
    required this.retainedBytes,
    required this.evictedCount,
  });

  /// Records in the bounded window after this admission.
  final int retainedCount;

  /// Observed bytes in the bounded window after this admission.
  final int retainedBytes;

  /// Records dropped from the window to admit this one, oldest first.
  final int evictedCount;
}

/// The record was refused and left no trace.
final class StreamObservationRefused extends StreamObservationAdmission {
  const StreamObservationRefused(this.reason);

  final StreamObservationRefusal reason;
}

/// Largest measured unit one record may describe.
const int streamObservationMaxRecordBytes = 64 * 1024;

/// Largest correlation identity one record may carry, in UTF-16 code units.
const int streamObservationMaxCorrelationChars = 128;

/// Largest number of admitted records the window retains.
const int streamObservationMaxRetainedRecords = 512;

/// Largest observed byte volume the window retains.
const int streamObservationMaxRetainedBytes = 4 * 1024 * 1024;

final class StreamObservationPort {
  StreamObservationPort({
    int maxRecordBytes = streamObservationMaxRecordBytes,
    int maxCorrelationChars = streamObservationMaxCorrelationChars,
    int maxRetainedRecords = streamObservationMaxRetainedRecords,
    int maxRetainedBytes = streamObservationMaxRetainedBytes,
  }) : maxRecordBytes = _positive(maxRecordBytes, 'maxRecordBytes'),
       maxCorrelationChars = _positive(
         maxCorrelationChars,
         'maxCorrelationChars',
       ),
       maxRetainedRecords = _positive(maxRetainedRecords, 'maxRetainedRecords'),
       maxRetainedBytes = _positive(maxRetainedBytes, 'maxRetainedBytes') {
    if (this.maxRecordBytes > this.maxRetainedBytes) {
      throw ArgumentError.value(
        this.maxRetainedBytes,
        'maxRetainedBytes',
        'must admit one record at maxRecordBytes',
      );
    }
  }

  /// Largest measured unit one admitted record may describe.
  final int maxRecordBytes;

  /// Largest correlation identity one admitted record may carry.
  final int maxCorrelationChars;

  /// Largest number of records the bounded window retains.
  final int maxRetainedRecords;

  /// Largest observed byte volume the bounded window retains.
  final int maxRetainedBytes;

  final ListQueue<StreamObservationRecord> _retained = ListQueue();
  var _retainedBytes = 0;
  var _evicted = 0;
  StreamObservationBackend? _backend;

  /// Whether an installed backend makes observation possible at all.
  bool get isInstalled => _backend != null;

  /// Records currently in the bounded window, oldest first.
  List<StreamObservationRecord> get retainedRecords =>
      UnmodifiableListView(_retained);

  /// Number of records currently in the bounded window.
  int get retainedCount => _retained.length;

  /// Observed bytes currently accounted in the bounded window.
  int get retainedBytes => _retainedBytes;

  /// Records the bounded window dropped under pressure since installation.
  int get evictedCount => _evicted;

  /// Installs the single observation backend.
  ///
  /// Reinstalling the same backend is a no-op; replacing one backend with
  /// another is refused so two owners cannot consume the same window.
  void installBackend(StreamObservationBackend backend) {
    final installed = _backend;
    if (identical(installed, backend)) return;
    if (installed != null) {
      throw StateError('stream_observation_backend_already_installed');
    }
    _backend = backend;
  }

  /// Submits one phase fact for admission.
  ///
  /// The rules are evaluated in this order and the record is constructed only
  /// after all of them pass: no installed backend, privacy classification,
  /// correlation identity bound, measured size bound. An admitted record enters
  /// the bounded window, drops the oldest retained records when the window is
  /// at its record or byte bound, and is then delivered to the backend.
  StreamObservationAdmission observe({
    required StreamObservationPhase phase,
    int sizeBytes = 0,
    String correlationId = '',
    StreamObservationLane lane = StreamObservationLane.ordered,
    int backlogBytes = 0,
    StreamObservationPrivacy privacy = StreamObservationPrivacy.aggregate,
  }) {
    if (sizeBytes < 0) {
      throw ArgumentError.value(sizeBytes, 'sizeBytes', 'must be non-negative');
    }
    if (backlogBytes < 0) {
      throw ArgumentError.value(
        backlogBytes,
        'backlogBytes',
        'must be non-negative',
      );
    }
    final backend = _backend;
    if (backend == null) {
      return const StreamObservationRefused(StreamObservationRefusal.noBackend);
    }
    if (privacy != StreamObservationPrivacy.aggregate) {
      return const StreamObservationRefused(
        StreamObservationRefusal.identifyingRecord,
      );
    }
    if (correlationId.length > maxCorrelationChars) {
      return const StreamObservationRefused(
        StreamObservationRefusal.oversizedCorrelation,
      );
    }
    if (sizeBytes > maxRecordBytes) {
      return const StreamObservationRefused(
        StreamObservationRefusal.oversizedRecord,
      );
    }
    final record = StreamObservationRecord(
      phase: phase,
      lane: lane,
      privacy: privacy,
      correlationId: correlationId,
      sizeBytes: sizeBytes,
      backlogBytes: backlogBytes,
    );
    var evicted = 0;
    while (_retained.isNotEmpty &&
        (_retained.length >= maxRetainedRecords ||
            _retainedBytes + sizeBytes > maxRetainedBytes)) {
      final dropped = _retained.removeFirst();
      _retainedBytes -= dropped.sizeBytes;
      evicted += 1;
    }
    _retained.addLast(record);
    _retainedBytes += sizeBytes;
    _evicted += evicted;
    try {
      backend.acceptStreamObservation(record);
    } on Object {
      // Observation is never allowed to fail the transport it observes.
    }
    return StreamObservationAdmitted(
      retainedCount: _retained.length,
      retainedBytes: _retainedBytes,
      evictedCount: evicted,
    );
  }
}

int _positive(int value, String name) {
  if (value <= 0) {
    throw ArgumentError.value(value, name, 'must be positive');
  }
  return value;
}
