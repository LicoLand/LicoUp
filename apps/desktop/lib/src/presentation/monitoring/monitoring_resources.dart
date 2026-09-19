import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/presentation/monitoring/monitoring_projection.dart';

/// Stable ownership scope for the monitoring feature presentation resources.
const monitoringPresentationScope = ResourceScope('monitoring');

/// Identity of the usage observation resource inside
/// [monitoringPresentationScope].
const monitoringUsageResource = ResourceKey(
  scope: monitoringPresentationScope,
  stableKey: 'usage',
);

/// Typed field group carrying the usage observation snapshot.
const monitoringUsageFields = ResourceFieldGroup<MonitoringProjection>(
  resource: monitoringUsageResource,
  name: 'overview',
);
