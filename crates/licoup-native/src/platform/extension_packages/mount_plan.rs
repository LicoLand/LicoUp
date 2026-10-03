//! The resource mount plan: what an installed appearance package renders as,
//! published for the client interface to mount.
//!
//! The plan is a *document*, not a program. It carries what every resource kind
//! serves, the contributions the selected generations declare, and the plain
//! values those contributions render. It has no field for a widget, a builder,
//! a callback, a script or a client object, so nothing a package installs can
//! cross into the interface as code.
//!
//! Two owners meet here and neither absorbs the other:
//!
//! * [`ResourceHost`](super::resources::ResourceHost) decides what each kind
//!   serves, which package generation serves it, and when a kind falls back to
//!   the client's own system appearance.
//! * [`plan_mount_with_resource_formats`](licoup_extension_contracts::ui::plan_mount_with_resource_formats)
//!   decides which interface contributions this host may mount at all, and
//!   names the reason for every one it refuses.
//!
//! The document is the whole answer. A renderer mounts one committed revision:
//! it refuses a contribution naming a primitive or action this host did not
//! register, and renders the declared default while a kind is falling back.

use std::collections::BTreeMap;

use licoup_extension_contracts::manifest::{CompositionComponent, ResourceDeclaration};
use licoup_extension_contracts::profile::ExtensionProfile;
use licoup_extension_contracts::ui::{
    Contribution, ContributionKind, HostPrimitive, plan_mount_with_resource_formats,
};
use serde_json::{Value, json};

use licoup_extension_contracts::manifest::ResourceKind;

use super::resources::{ResourceBinding, ResourceBindings, SystemDefault};

/// The document format this host publishes.
pub const MOUNT_PLAN_FORMAT: &str = "licoup.client.mount-plan.v1";

/// The document version this host publishes.
pub const MOUNT_PLAN_VERSION: u64 = 1;

/// The resource-view format a component renders, when it declares one.
///
/// A composition component names a compiled primitive, not a format: the
/// bounded pure-data format belongs to a resource-view contribution. The
/// planner therefore reads no format here, and a component is never refused for
/// one.
const fn component_resource_format(_component: &CompositionComponent) -> Option<String> {
    None
}

/// The profile ids this client serves.
///
/// A contribution that needs a profile outside this set is preserved and not
/// mounted, and the decision names why. The list is explicit rather than
/// derived: a client that serves a profile states it.
pub const SERVED_PROFILES: [&str; 0] = [];

/// The action names this client registered a handler for.
///
/// A contribution may invoke only an action named here. A name outside this set
/// is refused, so a package can never reach an operation the host did not
/// publish.
pub const HOST_ACTIONS: [&str; 0] = [];

/// The resource-view formats this interface compiles a renderer for.
///
/// A resource view naming a format outside this set is refused locally and
/// preserved, never drawn as another format.
pub const HOST_RESOURCE_VIEW_FORMATS: [&str; 0] = [];

/// One contribution the plan publishes.
///
/// The values are data: an identity, a primitive name, the references the host
/// already resolved, and plain values the primitive renders.
#[derive(Clone, Debug, PartialEq)]
pub struct PlannedContribution {
    /// The namespaced component identity.
    pub id: String,
    /// The compiled host primitive this component binds.
    pub primitive: HostPrimitive,
    /// The resource this component reads, when its declaration named one.
    pub resource_id: Option<String>,
    /// The bounded pure-data format a resource view renders.
    pub resource_format: Option<String>,
    /// The host-registered action this component may invoke.
    pub action_ref: Option<String>,
    /// Region ids the component occupies, in declaration order.
    pub regions: Vec<String>,
    /// Plain values the primitive renders; never code, never a widget.
    pub inputs: BTreeMap<String, Value>,
}

impl PlannedContribution {
    /// The contribution's wire form.
    pub fn to_wire(&self) -> Value {
        let mut value = serde_json::Map::new();
        value.insert("id".to_owned(), json!(self.id));
        value.insert("primitive".to_owned(), json!(self.primitive.as_str()));
        if let Some(resource_id) = &self.resource_id {
            value.insert("resourceId".to_owned(), json!(resource_id));
        }
        if let Some(resource_format) = &self.resource_format {
            value.insert("resourceFormat".to_owned(), json!(resource_format));
        }
        if let Some(action_ref) = &self.action_ref {
            value.insert("actionRef".to_owned(), json!(action_ref));
        }
        if !self.regions.is_empty() {
            value.insert("regions".to_owned(), json!(self.regions));
        }
        if !self.inputs.is_empty() {
            value.insert(
                "inputs".to_owned(),
                Value::Object(self.inputs.clone().into_iter().collect()),
            );
        }
        Value::Object(value)
    }
}

/// One decision about one contribution.
#[derive(Clone, Debug, PartialEq)]
pub struct MountDecision {
    /// The contribution this decision is about.
    pub contribution: PlannedContribution,
    /// `None` when it mounts; otherwise the host's stable reason.
    pub blocked: Option<&'static str>,
    /// The declaration member the refusal decided, when one is known.
    pub field: Option<&'static str>,
}

impl MountDecision {
    pub fn is_mounted(&self) -> bool {
        self.blocked.is_none()
    }
}

/// One published mount plan.
#[derive(Clone, Debug, PartialEq)]
pub struct ResourceMountPlan {
    /// The binding revision this plan was published from.
    pub revision: u64,
    /// The committed bindings this plan publishes.
    pub bindings: ResourceBindings,
    /// Every contribution the host considered, mounted and refused alike.
    pub decisions: Vec<MountDecision>,
}

impl ResourceMountPlan {
    /// The mounted contributions, in publication order.
    pub fn mounted(&self) -> impl Iterator<Item = &PlannedContribution> {
        self.decisions
            .iter()
            .filter(|decision| decision.is_mounted())
            .map(|decision| &decision.contribution)
    }

    /// The refused contributions with their stable reasons.
    pub fn refused(&self) -> impl Iterator<Item = (&PlannedContribution, &'static str)> {
        self.decisions
            .iter()
            .filter_map(|decision| decision.blocked.map(|reason| (&decision.contribution, reason)))
    }

    /// The wire document this plan publishes.
    ///
    /// Member order is fixed and collections are ordered, so the same published
    /// bindings always encode to the same document.
    pub fn to_document(&self) -> Value {
        let mut contributions: Vec<Value> = self.decisions.iter().map(decisions).collect();
        contributions.sort_by(|left, right| {
            left["id"]
                .as_str()
                .unwrap_or_default()
                .cmp(right["id"].as_str().unwrap_or_default())
        });

        let primitives: Vec<&str> = HostPrimitive::ALL
            .iter()
            .map(|primitive| primitive.as_str())
            .collect();
        let mut actions: Vec<&str> = HOST_ACTIONS.to_vec();
        actions.sort_unstable();

        json!({
            "format": MOUNT_PLAN_FORMAT,
            "version": MOUNT_PLAN_VERSION,
            "revision": self.revision,
            "servedProfiles": SERVED_PROFILES,
            "hostPrimitives": primitives,
            "hostActions": actions,
            "bindings": wire_bindings(&self.bindings),
            "fallbacks": wire_fallbacks(&self.bindings),
            "contributions": contributions,
        })
    }

    /// The contributions this plan decided shall mount, as the interface reads
    /// them. A refused contribution is not published: the interface cannot
    /// mount what the native owner refused, whatever a renderer does.
    pub fn mounted_document(&self) -> Value {
        let contributions: Vec<Value> = self
            .mounted()
            .map(PlannedContribution::to_wire)
            .collect();
        json!({ "contributions": contributions })
    }
}

/// One decision's document member.
///
/// A mounted contribution publishes its own shape; a refused one publishes the
/// stable reason and the field that decided, so the interface can report why
/// without re-deriving the rule.
fn decisions(decision: &MountDecision) -> Value {
    let mut value = match decision.contribution.to_wire() {
        Value::Object(members) => members,
        _ => serde_json::Map::new(),
    };
    if let Some(blocked) = decision.blocked {
        value.insert("blocked".to_owned(), json!(blocked));
        if let Some(field) = decision.field {
            value.insert("blockedField".to_owned(), json!(field));
        }
    }
    Value::Object(value)
}

/// The declared default one kind falls back to, as the document names it.
///
/// The interface reader publishes the same three names, so a value that leaves
/// this host is the value a renderer compares against.
pub const fn system_default_name(system: SystemDefault) -> &'static str {
    match system {
        SystemDefault::Appearance => "appearance",
        SystemDefault::Font => "font",
        SystemDefault::Locale => "locale",
    }
}

/// The bindings a published snapshot serves, one member per kind.
fn wire_bindings(bindings: &ResourceBindings) -> Vec<Value> {
    ResourceKind::ALL
        .iter()
        .map(|kind| match bindings.binding(*kind) {
            ResourceBinding::Selected {
                resource_id,
                package_id,
                package_generation,
                ..
            } => json!({
                "kind": kind.as_str(),
                "resourceId": resource_id,
                "packageId": package_id,
                "packageGeneration": package_generation,
            }),
            ResourceBinding::Default { system } => json!({
                "kind": kind.as_str(),
                "system": system_default_name(*system),
            }),
        })
        .collect()
}

/// The fallbacks a published snapshot recorded, one member each.
fn wire_fallbacks(bindings: &ResourceBindings) -> Vec<Value> {
    bindings
        .fallbacks()
        .map(|fallback| {
            json!({
                "kind": fallback.kind.as_str(),
                "resourceId": fallback.resource_id,
                "packageId": fallback.package_id,
                "reason": fallback.reason.as_str(),
            })
        })
        .collect()
}

/// Publish the mount plan for one package generation.
///
/// Every composition the generation carries becomes one planned contribution
/// per component, decided through the contract's own planner. A generation this
/// host no longer serves contributes nothing: the binding switch already
/// published the whole set, and a late plan must not resurrect the generation
/// before it.
pub fn plan_generation_mount(
    bindings: &ResourceBindings,
    package_id: &str,
    package_generation: u64,
    resources: &[ResourceDeclaration],
) -> ResourceMountPlan {
    let served = bindings.serves_package_generation(package_id, package_generation);
    let profiles: Vec<ExtensionProfile> = SERVED_PROFILES
        .iter()
        .filter_map(|id| ExtensionProfile::from_id(id))
        .collect();

    let mut decisions: Vec<MountDecision> = Vec::new();
    for resource in resources {
        let ResourceDeclaration::Composition { id, components, .. } = resource else {
            continue;
        };
        for component in components {
            decisions.push(decide(
                id,
                component,
                served,
                &profiles,
                HOST_RESOURCE_VIEW_FORMATS,
            ));
        }
    }

    ResourceMountPlan {
        revision: bindings.revision(),
        bindings: bindings.clone(),
        decisions,
    }
}

/// Decide one component through the contract's planner, then against this
/// host's own registration.
///
/// The two refusals stay distinguishable: a declaration the contract already
/// rejects is `contribution_invalid`, while a primitive this host build did not
/// compile is refused here rather than rendered as a neighbouring primitive.
fn decide(
    composition_id: &str,
    component: &CompositionComponent,
    generation_served: bool,
    profiles: &[ExtensionProfile],
    available_formats: [&'static str; 0],
) -> MountDecision {

    let contribution = contribution(composition_id, component);
    let planned = planned(composition_id, component);
    if !generation_served {
        return MountDecision {
            contribution: planned,
            blocked: Some("generation_not_served"),
            field: Some("packageGeneration"),
        };
    }
    if let Some(refusal) = components_registration(component) {
        return MountDecision {
            contribution: planned,
            blocked: Some(refusal.0),
            field: Some(refusal.1),
        };
    }
    let mut formats: Vec<&str> = available_formats.to_vec();
    formats.sort_unstable();
    let candidates = [contribution];
    let mounts = plan_mount_with_resource_formats(&candidates, profiles, &formats);
    match mounts.first().and_then(|mount| mount.blocked) {
        Some(blocked) => MountDecision {
            contribution: planned,
            blocked: Some(blocked),
            field: None,
        },
        None => MountDecision {
            contribution: planned,
            blocked: None,
            field: None,
        },
    }
}

/// Why this host cannot mount a component whose declaration is well formed.
fn components_registration(component: &CompositionComponent) -> Option<(&'static str, &'static str)> {
    if let Some(action_ref) = component.action_ref.as_deref() {
        if !HOST_ACTIONS.contains(&action_ref) {
            return Some(("action_unregistered", "components.actionRef"));
        }
    }
    None
}

/// One component as the contract's planner reads it.
///
/// A composition component binds a compiled primitive and, when it declares
/// one, a host-registered action; it never brings a primitive of its own and it
/// never names a callback. The contract's own `settings` contribution kind is
/// the closest published shape, so the planner's structural rules apply to it
/// unchanged.
fn contribution(composition_id: &str, component: &CompositionComponent) -> Contribution {
    Contribution {
        schema: licoup_extension_contracts::wire::UI.to_owned(),
        id: format!("{composition_id}#{}", component.component),
        kind: ContributionKind::Settings,
        title: component.component.clone(),
        required_profile: None,
        resource_ref: None,
        action_ref: component.action_ref.clone(),
        resource_format: component_resource_format(component),
        fields: Vec::new(),
        series: Vec::new(),
    }
}

/// The planned contribution one component publishes.
///
/// The values are the component's own declaration: its identity as the label
/// the primitive renders, and its declared regions. No value here is a widget,
/// a callback or a host object.
fn planned(composition_id: &str, component: &CompositionComponent) -> PlannedContribution {
    let mut inputs = BTreeMap::new();
    inputs.insert("label".to_owned(), json!(component.component));
    PlannedContribution {
        id: format!("{composition_id}#{}", component.component),
        primitive: component.primitive,
        resource_id: None,
        resource_format: component_resource_format(component),
        action_ref: component.action_ref.clone(),
        regions: Vec::new(),
        inputs,
    }
}
