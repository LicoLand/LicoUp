import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/presentation/agent_hub/agent_hub_projection.dart';

/// Stable ownership scope for the agent hub feature presentation resources.
const agentHubPresentationScope = ResourceScope('agent_hub');

/// Identity of the agent hub catalog resource inside
/// [agentHubPresentationScope].
const agentHubCatalogResource = ResourceKey(
  scope: agentHubPresentationScope,
  stableKey: 'catalog',
);

/// Typed field group carrying the agent hub catalog snapshot.
const agentHubCatalogFields = ResourceFieldGroup<AgentHubProjection>(
  resource: agentHubCatalogResource,
  name: 'overview',
);
