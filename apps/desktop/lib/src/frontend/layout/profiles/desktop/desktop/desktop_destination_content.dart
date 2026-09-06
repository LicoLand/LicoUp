import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';

/// Profile-private handoff of the shared destination content port.
///
/// The layout host invokes a profile's destination builder (which receives
/// the content port) before it invokes the shell builder, so every Desktop
/// destination frame records the port here. The Desktop shell uses it to host
/// feature panels inside floating cards; the port instance itself is the
/// stable renderer adapter owned by the client shell.
abstract final class DesktopDestinationContentRegistry {
  static LayoutDestinationContentPort? contentPort;
}
