import 'dart:io';

import 'package:licoup/src/composition/client_platform_port_adapters.dart';
import 'package:licoup/src/contracts/presentation/desktop_dock_layout.dart';
import 'package:licoup/src/frontend/shared/desktop_dock_layout_store.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';

/// Bridges owned desktop profile tests to the platform-backed dock store.
///
/// Owned profile tests never import platform code directly, so this fixture
/// hands out the real file-backed store through its renderer-facing port (via
/// the composition adapter) and the portable-data root as the opaque value
/// the store port expects.

/// The real file-backed dock layout store, adapted onto the renderer port.
DesktopDockLayoutStore createDesktopDockLayoutStore() =>
    const PlatformDesktopDockLayoutStoreAdapter();

/// Observes real dock-store writes so tests can await fire-and-forget model
/// persistence without replacing the file-backed implementation.
final class ObservedDesktopDockLayoutStore extends DesktopDockLayoutStore {
  ObservedDesktopDockLayoutStore(this._delegate);

  final DesktopDockLayoutStore _delegate;
  final List<Future<void>> _writes = [];

  int get writeCount => _writes.length;

  @override
  Future<DesktopDockLayoutSnapshot> load(Object portableData) =>
      _delegate.load(portableData);

  @override
  Future<void> save(Object portableData, DesktopDockLayoutSnapshot snapshot) {
    final write = _delegate.save(portableData, snapshot);
    _writes.add(write);
    return write;
  }

  Future<void> waitForWrites() => Future.wait(List.of(_writes));
}

/// A portable-data root confined to [directory], passed through as the
/// opaque value the store port expects.
Object createDesktopDockPortableData(Directory directory) =>
    PortableDataRoot(dataDirectoryOverride: directory);
