/// Composition root for declarative interface contributions (M21 over M30).
///
/// The composition owns the two objects the interface needs: the binding table
/// a feature fills with host-owned resources and actions, and the mount
/// registry that follows the committed catalog epoch. Features register
/// bindings here instead of writing global providers, and the app root places
/// [ExtensionUiComposition.buildHost] once in its tree.
///
/// The host lifetime is the composition lifetime: withdrawing an epoch releases
/// every contribution's subscription and prepared values, while the runtime
/// keeps sources shared by other consumers open.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_flutter/presentation_flutter.dart';
import 'package:presentation_runtime/presentation_runtime.dart';

import 'extension_ui_catalog_port.dart';

/// Wires declarative contributions into one application composition.
///
/// A feature registers the resources and actions its contributions name on
/// [bindings] before the epoch that declares them mounts; a contribution whose
/// binding is not registered yet stays locally unavailable instead of failing
/// the epoch.
///
/// [credentialPort] is the host's own custody for secrets. There is no
/// in-memory fallback: when the app does not inject the platform credential
/// bridge, secret fields of mounted contributions are locally unavailable and
/// no action is dispatched with a placeholder handle.
final class ExtensionUiComposition {
  factory ExtensionUiComposition({
    required PresentationRuntime runtime,
    ExtensionUiBindingRegistry? bindings,
    ExtensionUiCredentialPort? credentialPort,
    Set<DeclarativePrimitive>? availablePrimitives,
  }) => ExtensionUiComposition._(
    runtime: runtime,
    bindings: bindings ?? ExtensionUiBindingRegistry(),
    credentialPort: credentialPort,
    availablePrimitives: availablePrimitives,
  );

  ExtensionUiComposition._({
    required PresentationRuntime runtime,
    required this.bindings,
    required this.credentialPort,
    Set<DeclarativePrimitive>? availablePrimitives,
  }) : runtime = runtime,
       registry = ExtensionUiMountRegistry(
         runtime: runtime,
         bindings: bindings,
         credentialPort: credentialPort,
         availablePrimitives:
             availablePrimitives ??
             ExtensionUiMountRegistry.defaultExtensionUiPrimitives,
       );

  /// The presentation runtime every mounted contribution prepares against.
  final PresentationRuntime runtime;

  /// Host-owned bindings a feature fills before its contributions mount.
  final ExtensionUiBindingRegistry bindings;

  /// The mount registry that follows the committed catalog epoch.
  final ExtensionUiMountRegistry registry;

  /// Host custody for secrets, injected by the app composition; null when the
  /// platform bridge is absent.
  final ExtensionUiCredentialPort? credentialPort;

  StreamSubscription<ExtensionUiRegistrySnapshot>? _catalogSubscription;
  bool _disposed = false;

  /// Follows one catalog port.
  ///
  /// The subscription is taken before the current epoch is read, so a commit
  /// that lands between the two is not lost; mounting an epoch twice is a
  /// no-op, so the overlap cannot tear the interface down.
  void attachCatalog(ExtensionUiCatalogPort port) {
    if (_disposed) return;
    unawaited(_catalogSubscription?.cancel());
    _catalogSubscription = port.epochs.listen(registry.mount);
    final current = port.current;
    if (current != null) registry.mount(current);
  }

  /// Mounts one committed epoch document directly.
  void mountDocument(Map<String, Object?> document) {
    if (_disposed) return;
    registry.mount(ExtensionUiRegistrySnapshot.fromJson(document));
  }

  /// Withdraws the current epoch; a later commit mounts again.
  void withdraw() => registry.withdraw();

  /// The host surface the app root places in its tree.
  Widget buildHost({
    Key? key,
    Widget? hostTrustPrompt,
    Widget? emptyPlaceholder,
  }) => ExtensionUiHost(
    key: key,
    registry: registry,
    hostTrustPrompt: hostTrustPrompt,
    emptyPlaceholder: emptyPlaceholder,
  );

  Future<void> dispose() {
    if (_disposed) return Future<void>.value();
    _disposed = true;
    // Cancelling detaches the listener and [mount] refuses afterwards, so the
    // composition is inert immediately. The returned cancel future is only
    // completion bookkeeping and is deliberately not awaited: a caller that
    // disposes from a widget lifecycle must not depend on the feed's zone.
    unawaited(_catalogSubscription?.cancel());
    _catalogSubscription = null;
    registry.dispose();
    return Future<void>.value();
  }
}
