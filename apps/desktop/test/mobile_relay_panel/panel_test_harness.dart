import 'package:flutter/material.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

export '../fixtures/mobile_relay_binding_fixture.dart';
export 'package:flutter/material.dart';
export 'package:licoup/src/contracts/generated/secure_mesh.g.dart';
export 'package:licoup/src/contracts/mobile_pairing_presentation.dart';
export 'package:licoup/src/contracts/mobile_relay/mobile_relay_models.dart';
export 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_relay_panel.dart';
export 'package:licoup/src/frontend/features/mobile_relay/ui/shell_pair_device_dialog.dart';
export 'package:licoup/src/frontend/shared/ui/minimal_scan_icon.dart';
export 'package:licoup/src/frontend/shared/ui/panel_frame.dart';
export 'package:licoup/src/frontend/shared/ui/theme.dart';
export 'package:licoup/src/presentation/mobile_relay/mobile_relay_binding.dart';
export 'package:licoup/src/presentation/mobile_relay/mobile_relay_effect.dart';
export 'package:licoup/src/presentation/mobile_relay/mobile_relay_intent.dart';
export 'package:licoup/src/presentation/mobile_relay/mobile_relay_projection.dart';
export 'package:licoup/src/presentation/presentation_semantics.dart';
export 'package:flutter_test/flutter_test.dart';
export 'package:presentation_contract/presentation_contract.dart';
export 'package:qr_flutter/qr_flutter.dart';

Widget mobileRelayPanelTestApp({
  required Widget child,
  TargetPlatform platform = TargetPlatform.macOS,
}) {
  return MaterialApp(
    theme: buildLicoTheme().copyWith(platform: platform),
    home: Scaffold(body: child),
  );
}
