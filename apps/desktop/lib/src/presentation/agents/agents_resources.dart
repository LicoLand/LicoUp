import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/presentation/agents/agents_projection.dart';

/// Stable ownership scope for the agents feature presentation resources.
const agentsPresentationScope = ResourceScope('agents');

/// Identity of the agent catalog resource inside [agentsPresentationScope].
const agentsCatalogResource = ResourceKey(
  scope: agentsPresentationScope,
  stableKey: 'catalog',
);

/// Typed field group carrying the agent catalog snapshot.
const agentsCatalogFields = ResourceFieldGroup<AgentsProjection>(
  resource: agentsCatalogResource,
  name: 'overview',
);
