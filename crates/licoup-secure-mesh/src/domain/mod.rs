// Composition that runs a secure-mesh surface against this endpoint. The
// product-facing MLS surface owns the group operations this endpoint performs,
// their durable state and the selected-custody context they run under.
//
// The command runtime composition is still in `licoup-native`: it resolves the
// local Agent inventory and the conversation history surface, which are not this
// crate's to own, so declaring it here would point the protocol crate at the
// conversation domain.
pub mod secure_mesh_mls;
