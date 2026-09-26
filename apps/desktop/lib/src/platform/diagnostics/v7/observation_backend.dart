import 'dart:developer' show TimelineTask;

import 'package:licoup/src/platform/diagnostics/v7/observation_segment.dart';

/// Consumer of drained observation records.
///
/// The backend is the replaceable half of the port. Implementations run only
/// from `ObservationProbe.drain`, never from a business path, so a slow backend
/// delays the next drain and the bounded buffer refuses records instead of
/// stalling a caller.
///
/// A backend must not open a second history store, write files, or reach a
/// network. Both shipped backends reuse owners that already exist.
abstract interface class ObservationTelemetryBackend {
  /// Consumes one drained record.
  void emit(ObservationSegmentRecord record);
}

/// The diagnostic default: consume and discard.
final class NullObservationTelemetryBackend
    implements ObservationTelemetryBackend {
  const NullObservationTelemetryBackend();

  @override
  void emit(ObservationSegmentRecord record) {}
}

/// Forwards records to the existing `dart:developer` timeline.
///
/// The renderer already publishes its causal spans through `TimelineTask`, so
/// this backend reuses that sink rather than adding a second trace store. One
/// task carries every record, so the port adds no timeline task per segment.
final class TimelineObservationTelemetryBackend
    implements ObservationTelemetryBackend {
  TimelineObservationTelemetryBackend({this.category = defaultCategory});

  /// Category used when the caller does not name one.
  static const String defaultCategory = 'licoup.observation';

  /// Timeline category records are published under.
  final String category;

  late final TimelineTask _task = TimelineTask(filterKey: category);

  @override
  void emit(ObservationSegmentRecord record) {
    _task.instant(
      record.phase.wireName,
      arguments: <String, Object>{
        'kind': record.kind.wireName,
        'category': category,
        'startedMicros': record.startedMicroseconds,
        'durationMicros': record.durationMicroseconds,
        'links': record.links.length,
        ...record.ids.toJson(),
      },
    );
  }
}
