import 'package:flutter/widgets.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/contracts/presentation/layout_state_port.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_features.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_port.dart';
import 'package:licoup/src/frontend/layout/layout_registry.dart';

abstract interface class ShellRendererPort {
  LayoutRegistry get layoutRegistry;

  LayoutStatePort get layoutStateStore;

  LayoutChromePort get chrome;

  LayoutChromeFeatures createChromeFeatures(
    ValueNotifier<bool> auxChromePanelOpen,
  );

  GlobalKey createAgentsHomeKey();

  Widget buildDestination(
    BuildContext context,
    ClientSection destination, {
    required GlobalKey agentsHomeKey,
  });

  void resetAgentsHome(GlobalKey agentsHomeKey);
}
