import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/frontend/binding/projected_presentation_source.dart';
import 'package:licoup/src/presentation/monitoring/monitoring_projection.dart';
import 'package:licoup/src/presentation/monitoring/monitoring_resources.dart';

/// The agent usage resource adapter over the monitoring projection owner.
///
/// The source/subscription lifecycle — epoch identity, monotonic versions, one
/// consistency group per accepted change, subscribe-before-read opening and the
/// observer ref count — belongs to [ProjectedPresentationSource]. This type
/// declares only the resource identity this feature owns.
final class MonitoringPresentationSource
    extends
        ProjectedPresentationSource<
          MonitoringProjection,
          MonitoringProjection
        > {
  MonitoringPresentationSource({required super.projection})
    : super(fieldGroup: monitoringUsageFields, epochKey: 'monitoring-usage');
}
