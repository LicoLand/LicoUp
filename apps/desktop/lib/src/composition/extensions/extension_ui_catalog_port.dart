/// The stable seam between the native extension catalog and the contribution
/// host.
///
/// The catalog owner (M22) commits whole registry epochs; this port hands the
/// interface host one immutable snapshot per commit. The document carries only
/// the binding facts the interface needs — epoch, served profiles, and each
/// contribution with its instance and generation — never a copy of the
/// instance lifecycle ledger.
///
/// A native catalog implements this port by projecting `CatalogSnapshot` into
/// [ExtensionUiRegistrySnapshot]; [ExtensionUiCatalogDocumentPort] is the
/// document-fed adapter used until that projection is wired.
library;

import 'dart:async';

import 'package:presentation_flutter/presentation_flutter.dart';

/// Committed interface epochs of the running extension catalog.
abstract interface class ExtensionUiCatalogPort {
  /// The last committed epoch this port read, or null before the first commit.
  ExtensionUiRegistrySnapshot? get current;

  /// Subsequent committed epochs; a new consumer seeds itself from [current].
  Stream<ExtensionUiRegistrySnapshot> get epochs;
}

/// A catalog port fed by decoded epoch documents.
///
/// Publishing one document is one commit: the previous epoch is replaced as a
/// whole. The port does not interpret instance state; it only decodes the
/// interface projection.
final class ExtensionUiCatalogDocumentPort implements ExtensionUiCatalogPort {
  final StreamController<ExtensionUiRegistrySnapshot> _epochs =
      StreamController<ExtensionUiRegistrySnapshot>.broadcast();
  ExtensionUiRegistrySnapshot? _current;
  bool _closed = false;

  @override
  ExtensionUiRegistrySnapshot? get current => _current;

  @override
  Stream<ExtensionUiRegistrySnapshot> get epochs => _epochs.stream;

  /// Whether a composition is still following this port.
  bool get hasListeners => _epochs.hasListener;

  /// Publishes one committed epoch document.
  void publishDocument(Map<String, Object?> document) {
    if (_closed) return;
    final snapshot = ExtensionUiRegistrySnapshot.fromJson(document);
    _current = snapshot;
    _epochs.add(snapshot);
  }

  Future<void> dispose() {
    if (_closed) return Future<void>.value();
    _closed = true;
    // Closing is synchronous for this feed; the done future of a broadcast
    // controller can stay pending when its last subscription was cancelled
    // first, so awaiting it would deadlock a caller that disposed the
    // composition and then the port.
    unawaited(_epochs.close());
    return Future<void>.value();
  }
}
