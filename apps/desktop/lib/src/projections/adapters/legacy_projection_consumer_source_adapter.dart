import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/projections/projection_consumer.dart';

/// Read-only transition edge for existing projection consumers.
///
/// The concrete consumer and its lifecycle stay owned by composition.
final class LegacyProjectionConsumerSourceAdapter<T>
    implements ProjectionSource<T> {
  const LegacyProjectionConsumerSourceAdapter(this._consumer);

  final ProjectionConsumer<T> _consumer;

  @override
  T get current => _consumer.current;

  @override
  Stream<T> get changes => _consumer.projections;
}
