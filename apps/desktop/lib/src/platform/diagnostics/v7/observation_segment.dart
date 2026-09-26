import 'package:licoup/src/platform/diagnostics/v7/observation_ids.dart';

/// Waiting versus work.
enum ObservationSegmentKind {
  /// Time a caller spent waiting; no progress happened here.
  wait('wait'),

  /// Time spent making progress.
  work('work');

  const ObservationSegmentKind(this.wireName);

  /// The stable wire name of this kind.
  final String wireName;
}

/// The measured interval a segment describes.
///
/// The set is the contract's telemetry list: admission wait, DB transaction,
/// queue wait, adapter first event, prepare CPU, prepare queue, build, raster,
/// and input display. Each phase pins its own kind, so one interval cannot be
/// classified two ways by two callers.
enum ObservationPhase {
  /// Waiting before an effect is admitted.
  admissionWait('admission_wait', ObservationSegmentKind.wait),

  /// A database transaction.
  databaseTransaction('database_transaction', ObservationSegmentKind.work),

  /// Waiting in an asynchronous queue.
  queueWait('queue_wait', ObservationSegmentKind.wait),

  /// Latency from dispatch until the adapter's first event.
  adapterFirstEvent('adapter_first_event', ObservationSegmentKind.wait),

  /// CPU spent preparing an input.
  prepareCpu('prepare_cpu', ObservationSegmentKind.work),

  /// Waiting for prepare capacity.
  prepareQueue('prepare_queue', ObservationSegmentKind.wait),

  /// Rendering build work.
  build('build', ObservationSegmentKind.work),

  /// Raster work.
  raster('raster', ObservationSegmentKind.work),

  /// User-visible input-to-display latency.
  ///
  /// This is waiting: it is the latency a person perceived, while any work
  /// inside it is already attributed to a build or raster segment.
  inputDisplay('input_display', ObservationSegmentKind.wait);

  const ObservationPhase(this.wireName, this.kind);

  /// The stable wire name of this phase.
  final String wireName;

  /// Whether the interval is time spent waiting or time spent working.
  final ObservationSegmentKind kind;
}

/// Why two segments are related without one calling the other.
enum ObservationLinkRelation {
  /// The linked segment is one of several parallel predecessors of this one.
  predecessor('predecessor'),

  /// The linked segment produced the queue item this one consumed.
  queueProducer('queue_producer');

  const ObservationLinkRelation(this.wireName);

  /// The stable wire name of this relation.
  final String wireName;
}

/// A relation from one segment to another causal context.
///
/// Links are the contract's answer to parallel predecessors and asynchronous
/// queues: the linked context owns its own timing, and this segment only states
/// how it depends on it.
final class ObservationSpanLink {
  const ObservationSpanLink({required this.ids, required this.relation});

  /// Correlation ids of the linked context.
  final ObservationIds ids;

  /// How the linked context relates to this segment.
  final ObservationLinkRelation relation;

  /// The wire shape.
  Map<String, Object> toJson() => <String, Object>{
    'correlation': ids.toJson(),
    'relation': relation.wireName,
  };
}

/// One completed waiting or work interval.
final class ObservationSegmentRecord {
  const ObservationSegmentRecord({
    required this.phase,
    required this.ids,
    required this.startedMicroseconds,
    required this.durationMicroseconds,
    this.links = const <ObservationSpanLink>[],
  });

  /// Which interval was measured.
  final ObservationPhase phase;

  /// Ids of this segment's causal context.
  final ObservationIds ids;

  /// Clock reading when the segment opened, in microseconds.
  final int startedMicroseconds;

  /// How long the segment stayed open, in microseconds.
  final int durationMicroseconds;

  /// Parallel predecessors and queue producers, bounded by the privacy budget.
  final List<ObservationSpanLink> links;

  /// Whether this record describes waiting or work.
  ObservationSegmentKind get kind => phase.kind;

  /// The wire shape.
  Map<String, Object> toJson() => <String, Object>{
    'phase': phase.wireName,
    'kind': kind.wireName,
    'correlation': ids.toJson(),
    'startedMicros': startedMicroseconds,
    'durationMicros': durationMicroseconds,
    if (links.isNotEmpty)
      'links': <Object>[for (final link in links) link.toJson()],
  };
}

/// An open segment.
///
/// Holding one costs a clock reading and nothing else; a probe that is switched
/// off never opens one.
final class ActiveObservationSegment {
  ActiveObservationSegment._({
    required this.phase,
    required this.ids,
    required this.startedMicroseconds,
    required int Function() clock,
  }) : _clock = clock;

  /// Which interval this segment measures.
  final ObservationPhase phase;

  /// Ids carried by this segment.
  final ObservationIds ids;

  /// Clock reading taken when the segment opened.
  final int startedMicroseconds;

  final int Function() _clock;
  final List<ObservationSpanLink> _links = <ObservationSpanLink>[];

  /// Attaches a link to a parallel predecessor or queue producer.
  void addLink({
    required ObservationIds ids,
    required ObservationLinkRelation relation,
  }) {
    _links.add(ObservationSpanLink(ids: ids, relation: relation));
  }

  /// Closes the segment and reads the clock once more.
  ObservationSegmentRecord finish() => ObservationSegmentRecord(
    phase: phase,
    ids: ids,
    startedMicroseconds: startedMicroseconds,
    durationMicroseconds: _nonNegative(_clock() - startedMicroseconds),
    links: List<ObservationSpanLink>.unmodifiable(_links),
  );

  /// Builds the open segment for a probe.
  static ActiveObservationSegment open({
    required ObservationPhase phase,
    required ObservationIds ids,
    required int startedMicroseconds,
    required int Function() clock,
  }) => ActiveObservationSegment._(
    phase: phase,
    ids: ids,
    startedMicroseconds: startedMicroseconds,
    clock: clock,
  );
}

int _nonNegative(int value) => value < 0 ? 0 : value;
