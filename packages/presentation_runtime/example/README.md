# Runtime provider assembly example

provider_assembly.dart is a pure-Dart Riverpod composition example. It uses
the official Provider, ProviderContainer, ProviderListenable, and override
APIs; a Flutter application can place the same override set at its root
ProviderScope.

The three synthetic sources implement the contract source port and carry
typed ResourceSnapshot values. The composition supplies those sources and
their snapshot listenables with overrides, then wraps each listenable in the
existing PresentationProviderEntry boundary. The snapshots retain their
source epoch, version, and consistency-group identity.

The unavailable defaults are intentional: source ownership belongs to
application composition, while this package currently exposes the official
Riverpod entry declaration. No example provider starts a task, performs I/O,
or creates a second presentation state machine.
