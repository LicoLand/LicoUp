import 'package:flutter/material.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_chrome_tabs.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_notification_bell.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_features.dart';

/// Host-side implementation of [LayoutChromeFeatures]: builds the
/// feature-owned chrome-band content (conversation tabs, notification bell)
/// with full controller access, for layout profiles to mount through
/// [LayoutChromeFeaturesScope].
final class ClientChromeFeatures implements LayoutChromeFeatures {
  ClientChromeFeatures(this._controller);

  final ClientController _controller;
  final ValueNotifier<bool> _auxChromePanelOpen = ValueNotifier<bool>(false);

  @override
  ValueNotifier<bool> get auxChromePanelOpen => _auxChromePanelOpen;

  void _closeAuxChromePanel() {
    _auxChromePanelOpen.value = false;
  }

  @override
  Widget buildConversationTabs(BuildContext context) =>
      MessagingConversationTabStrip(
        controller: _controller,
        onCloseAuxChromePanel: _closeAuxChromePanel,
      );

  @override
  Widget buildNotificationBell(BuildContext context) =>
      MessagingNotificationBell(
        controller: _controller,
        onCloseAuxChromePanel: _closeAuxChromePanel,
      );
}
