# Contract author examples

These examples are pure Dart. They show the small set of values a feature
author owns:

- progress_example.dart prepares two blocks under one preparation key, keeps
  the sealed block in the immutable prefix and the growing block in the mutable
  tail, and installs two changed field groups through ConsistencyGroupInstall.
  A revoked group refuses the member that arrives later.
- list_example.dart keeps a sealed row block in the mutable tail until the
  summary block it references is sealed in the same content revision, declares
  the query field group as a plain referenced input, and keeps typed
  list inputs/actions separate from a source-attributed error.
- validated_input_example.dart keeps renderer-local draft text separate from
  the submitted value and from asynchronous validation feedback, so local
  editing never moves the prepared source position.

Each example also declares a third-party contribution from ordinary data
inputs: a chart in progress_example.dart, a table in list_example.dart, and a
form plus a command in validated_input_example.dart. A contribution only names
the host primitive it needs; when the running shell does not provide it, it
reports a local DeclarativeUnavailable while the resource keeps merging its
consistency groups unchanged.

author_support.dart contains only example support: ExampleErrorAttribution
shows how an application can retain scope, resource, and operation identity
without becoming a second error contract, and acceptMember builds the
per-member acceptance the contract's install gate expects.

Actions are created with CallbackActions, so the originating scope is pinned
when the action is created. The examples do not require Flutter, Riverpod, code
generation, or a live application facade.
