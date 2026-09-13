# Global model registry

English · [简体中文](MODEL-REGISTRY.zh-CN.md) · [Architecture](README.md)

This document owns canonical model identity in the Rust client core. An Agent,
a model developer, a serving provider, a selectable model ID, and a model are
distinct identities. Flutter renders the core's model IDs and display names;
it does not maintain another directory or normalize Agent-specific names.

## Directory and refresh

The process shares an immutable registry snapshot. Public model facts and
provider-to-model references come from the open-source
[Models.dev source catalog](https://github.com/anomalyco/models.dev). Refresh
reads the official source archive to preserve explicit `base_model` references.
The local Agent catalog retains native selector IDs, names, and admitted
options; the registry adds canonical identity to that projection. A matching
display name is not permission to invoke a model or change its dispatch selector.

An explicit user refresh updates the public directory and then refreshes local
usage. Background usage reads do not download a directory for each report or
record. When no directory exists, the desktop first presents local statistics
and attempts one background directory refresh. Failure does not start an
automatic retry loop; an explicit refresh can retry. Readers share an indexed
snapshot; a successful refresh publishes its
replacement atomically. Other local processes observe the updated directory at
a request boundary. A failed download or parse leaves the last usable directory
available and exposes the refresh failure to the caller.

An explicitly selected state root owns its own directory cache. Its report
captures that root's snapshot without inheriting or replacing the default
process registry; the normal desktop path continues to share the singleton.

Refresh downloads public facts only. It sends no usage, model selections,
credentials, conversations, or native history to the catalog service. Registry
commands remain local CLI capabilities, outside the remote Subagents MCP surface.

## Canonical identity

The registry indexes canonical IDs and names separately from provider selectors.
An exact canonical identity stays stable when a provider later redirects an API
alias. Explicit provider metadata disambiguates provider selectors; an Agent
name alone does not identify its serving provider. Matching must be
unique: formatting differences, an Agent wrapper, a context-window suffix, and
request effort or speed controls cannot create a second identity for the same
model. Versions, meaningful model variants, and different modalities stay distinct.

Formal provider IDs have their own namespace. Display-name aliases cannot
override a provider ID or turn a lookup miss into another provider's selector.
Historical usage admits canonical identities and concrete version aliases;
today's floating endpoint route cannot establish which version answered an old
request. A retained report keeps its previously confirmed canonical assignment
even after that model leaves the current directory. Display text can still update.

A structured selector is parsed as a structure. For example, `id: k3`,
`providerID: kimi-for-coding`, and `variant: max` supply three separate facts;
their serialized JSON is never a model name. A context variant that explicitly
refers to the same base model shares its identity. A provider-only or automatic
selector does not prove which model answered. Ambiguous and unknown names are
not assigned to a guessed model.

Upstream changes can extend the directory without per-model frontend adapters.
The directory is not proof that every private, renamed, or newly released model
has already been cataloged. Unresolved raw identities remain available for a
later revision to resolve without losing their token counts.

## Display names

The same registry supplies user-facing names independently of identity lookup.
Catalog product names retain brand spelling and model versions. Presentation
uses spaces for word separators, such as `DeepSeek V4 Flash`, `DeepSeek V4 Pro`,
and `Claude Fable 5.1`; the GPT version prefix keeps its hyphen in `GPT-6 Astra`.
Provider namespaces, API separators and request-control suffixes are not display
names. Uncataloged labels receive the same readable word formatting, including
`GPT Reserve` and `Grok Bot`, without assigning a guessed canonical identity.

Read-only workflow inspection also supplies names for saved model selectors that
are absent from the current selection catalog. Flutter carries those labels into
saved-route chips without changing the binding, authorization digest, or dispatch
selector. Rendering a label does not rescan the catalog.

Official product references include [Claude Fable](https://www.anthropic.com/claude/fable)
and [DeepSeek's V4.1 announcement](https://www.deepseek.com/en/news/deepseek-v4-1-flash/).
Serving aliases can change independently of the named model.
Refreshing those aliases must not rename older, explicit version identities.

## Usage and actual reasoning effort

Caches retain original model selectors and actual request controls separately
from canonical report identity. Fresh reports use the snapshot's historical
identity rules; retained reports preserve confirmed assignments and can resolve
previously unknown concrete identities. Canonical model totals combine all
source Agents; source totals and their available effort and speed breakdowns
remain numeric facts beneath it.

Actual effort comes from recorded request, turn, message, or explicit selector
metadata. Extraction covers the runtime Agent inventory and preserves request
context through incremental parsing and cache reload. Supported reasoning
options, capability scores, and current configuration cannot establish an
earlier request's effort. Parser changes migrate retained accounting facts and
refresh reconstructible metadata. They do not erase sealed history or invent
request controls that its retained records lack.

The runtime Agent inventory determines scan coverage. Existing independent
history sources, including Kimi Desktop, remain readable even when they are not
runtime dispatch Agents. A source with no retained token metadata reports its
unavailability; adding its Agent to the scan cannot invent historical tokens.
An arbitrary named model preset is not a reasoning effort unless the same
record supplies the actual option or the selector has a known effort meaning.

Lico Agent records numeric usage for each model response, including responses
that call tools. Its transcript keeps those records separate from conversation
text, and resuming a conversation excludes them from model input. Completed
calls remain counted when a later call fails. Response model identity takes
precedence over the explicit model requested for that call.

Missing effort stays absent: no `Unspecified`, `default`, or `unknown` row.
Partial effort coverage does not reduce model or source totals. Known effort
rows describe only requests that supplied that fact. Normalization preserves
prompt, cached-input, completion, total-token, and request counts.

The [desktop usage scenario](../functionality/CLIENT-DESKTOP.md#scenario-s-05--desktop-token-usage)
owns source and deduplication boundaries. The
[design system](../functionality/DESIGN-SYSTEM.md) owns palettes and hover cards;
neither creates another model identity authority.
