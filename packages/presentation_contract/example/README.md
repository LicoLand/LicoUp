# Contract author examples

These examples are pure Dart. They show the small set of values a feature
author owns:

- progress_example.dart uses typed progress inputs/actions and stages two
  changed field groups before exposing one consistency-group installation.
- list_example.dart keeps typed list inputs/actions separate from a
  source-attributed error.
- validated_input_example.dart keeps local input values and typed actions
  separate from asynchronous validation feedback.

author_support.dart contains only example support. ExampleErrorAttribution
shows how an application can retain scope, resource, and operation identity;
it is not a second error contract. AtomicExampleInstaller makes the
consistency-group boundary visible without introducing a subscription,
provider, or preparation state machine.

Actions are created with CallbackActions, so the originating scope is pinned
when the action is created. The examples do not require Flutter, Riverpod,
code generation, or a live application facade.
