import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/frontend/binding/projected_presentation_source.dart';
import 'package:licoup/src/presentation/agents/agents_projection.dart';
import 'package:licoup/src/presentation/agents/agents_resources.dart';

/// The agent catalog resource adapter over the agents projection owner.
///
/// The source/subscription lifecycle — epoch identity, monotonic versions, one
/// consistency group per accepted change, subscribe-before-read opening and the
/// observer ref count — belongs to [ProjectedPresentationSource]. This type
/// declares only the resource identity this feature owns.
final class AgentsPresentationSource
    extends ProjectedPresentationSource<AgentsProjection, AgentsProjection> {
  AgentsPresentationSource({required super.projection})
    : super(fieldGroup: agentsCatalogFields, epochKey: 'agents-catalog');
}
