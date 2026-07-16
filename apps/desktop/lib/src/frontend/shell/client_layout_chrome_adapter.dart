import 'package:flutter/widgets.dart';

import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/frontend/features/mobile_relay/ui/mobile_relay_panel.dart';
import 'package:flutter_client/src/frontend/layout/layout_chrome_port.dart';

typedef LayoutPairingAction = Future<void> Function(BuildContext context);

/// Converts the application controller into the bounded semantic state used by
/// every layout profile's chrome.
final class ClientLayoutChromeAdapter extends ChangeNotifier
    implements LayoutChromePort {
  ClientLayoutChromeAdapter(
    this._controller, {
    LayoutPairingAction? pairingAction,
  }) {
    _pairingAction =
        pairingAction ??
        (context) => showMobileRelayPopup(context, _controller);
    _value = _snapshotFromController();
    _controller.addListener(_handleControllerChanged);
  }

  final ClientController _controller;
  late final LayoutPairingAction _pairingAction;

  late LayoutChromeSnapshot _value;
  bool _disposed = false;

  @override
  LayoutChromeSnapshot get value => _value;

  @override
  Future<void> openPairing(BuildContext context) => _pairingAction(context);

  void _handleControllerChanged() {
    if (_disposed) {
      return;
    }
    final next = _snapshotFromController();
    if (next == _value) {
      return;
    }
    _value = next;
    notifyListeners();
  }

  LayoutChromeSnapshot _snapshotFromController() {
    final status = LayoutChromeStatusSnapshot(
      message: _controller.displayStatusMessage,
      caption: _controller.displayStatusCaption,
    );
    return LayoutChromeSnapshot(status: status);
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _controller.removeListener(_handleControllerChanged);
    super.dispose();
  }
}
