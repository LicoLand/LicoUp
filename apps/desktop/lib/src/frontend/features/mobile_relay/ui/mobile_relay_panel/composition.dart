import 'package:flutter/material.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_relay_panel/pairing.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_relay_panel/scan.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_relay_panel/trust.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/secure_mesh_approval_card.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/secure_mesh_capability_card.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/secure_mesh_file_sync_card.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/platform/client_platform.dart';
import 'package:licoup/src/frontend/shared/ui/lico_section_header.dart';
import 'package:licoup/src/frontend/shared/ui/minimal_scan_icon.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

class MobileRelayPanel extends StatefulWidget {
  const MobileRelayPanel({super.key, required this.controller});

  final ClientController controller;

  @override
  State<MobileRelayPanel> createState() => _MobileRelayPanelState();
}

class _MobileRelayPanelState extends State<MobileRelayPanel> {
  late final TextEditingController _stationBaseUrlController;

  ClientController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _stationBaseUrlController = TextEditingController(
      text: controller.mobileRelayConfig.stationBaseUrl,
    );
  }

  @override
  void didUpdateWidget(covariant MobileRelayPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = controller.mobileRelayConfig.stationBaseUrl;
    if (_stationBaseUrlController.text != next) {
      _stationBaseUrlController.text = next;
    }
  }

  @override
  void dispose() {
    _stationBaseUrlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final config = controller.mobileRelayConfig;
    final paired = config.paired;
    final mobileClient = isMobileClientPlatform(context);
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        LicoSectionHeader(
          title: strings.pairing,
          leading: MinimalScanIcon(color: colors.accent, size: 22),
        ),
        const SizedBox(height: 12),
        if (mobileClient) ...[
          MobileRelayScanPairingPrompt(
            colors: colors,
            label: strings.scanPairingPrompt,
          ),
          const SizedBox(height: 12),
          MobileRelayPairingInfoRow(
            label: strings.status,
            value: paired ? strings.paired : strings.waiting,
          ),
          MobileRelayPairingInfoRow(
            label: strings.pairingId,
            value: config.pairingId,
          ),
          MobileRelayPairingInfoRow(
            label: strings.expires,
            value: config.lastPairingExpiresAt,
          ),
        ] else
          MobileRelayPairingWorkspaceCard(
            controller: controller,
            stationBaseUrlController: _stationBaseUrlController,
            presentation: controller.mobilePairingPresentation,
            onGenerate: controller.createMobilePairing,
          ),
        if (paired && config.trustPresentation != null) ...[
          const _MobileRelayDivider(),
          MobileRelayTrustVerificationCard(
            presentation: config.trustPresentation!,
            colors: colors,
          ),
        ],
        if (paired) ...[
          const _MobileRelayDivider(),
          SecureMeshFileSyncCard(controller: controller),
          const SizedBox(height: 12),
          SecureMeshApprovalCard(controller: controller),
        ],
        if (controller.secureMeshCapabilityProjection != null) ...[
          const _MobileRelayDivider(),
          SecureMeshCapabilityCard(
            projection: controller.secureMeshCapabilityProjection!,
          ),
        ],
      ],
    );
  }
}

class _MobileRelayDivider extends StatelessWidget {
  const _MobileRelayDivider();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: Divider(height: 1, color: context.licoColors.line),
    );
  }
}

/// Floating pairing card opened from top-bar / sidebar-rail chrome.
Future<void> showMobileRelayPopup(
  BuildContext context,
  ClientController controller,
) {
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (context) {
      return Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720, maxHeight: 640),
          child: Material(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(14),
            clipBehavior: Clip.antiAlias,
            child: MobileRelayPanel(controller: controller),
          ),
        ),
      );
    },
  );
}
