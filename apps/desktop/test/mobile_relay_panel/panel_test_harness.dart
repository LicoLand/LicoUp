import 'package:flutter/material.dart';
import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/platform/native_client/agent_service.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

export 'package:flutter/material.dart';
export 'package:licoup/src/application/controller/client_controller.dart';
export 'package:licoup/src/contracts/mobile_pairing_presentation.dart';
export 'package:licoup/src/contracts/mobile_relay/mobile_relay_models.dart';
export 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_relay_panel.dart';
export 'package:licoup/src/frontend/shared/ui/minimal_scan_icon.dart';
export 'package:licoup/src/frontend/shared/ui/theme.dart';
export 'package:flutter_test/flutter_test.dart';
export 'package:qr_flutter/qr_flutter.dart';

ClientController mobileRelayPanelTestController() {
  return ClientController(
    agentService: AgentService(
      runCliExecutable: (_, _, _) async {
        throw StateError('mobile relay panel leaf test does not execute CLI');
      },
    ),
  );
}

Widget mobileRelayPanelTestApp({
  required Widget child,
  TargetPlatform platform = TargetPlatform.macOS,
}) {
  return MaterialApp(
    theme: buildLicoTheme().copyWith(platform: platform),
    home: Scaffold(body: child),
  );
}
