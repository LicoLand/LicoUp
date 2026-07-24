import 'package:flutter/material.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_relay_panel/pairing.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_relay_panel/scan.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_relay_panel/trust.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/secure_mesh_approval_card.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/secure_mesh_capability_card.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/secure_mesh_file_sync_card.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/secure_mesh_skill_sync_card.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/platform/client_platform.dart';
import 'package:licoup/src/frontend/shared/ui/minimal_scan_icon.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

class MobileRelayPanel extends StatefulWidget {
  const MobileRelayPanel({super.key, required this.controller});

  final ClientController controller;

  @override
  State<MobileRelayPanel> createState() => _MobileRelayPanelState();
}

class _MobileRelayPanelState extends State<MobileRelayPanel> {
  late final TextEditingController _customUrlController;

  ClientController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _customUrlController = TextEditingController(
      text: controller.mobileRelayConfig.effectiveGatewayUrl,
    );
  }

  @override
  void didUpdateWidget(covariant MobileRelayPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = controller.mobileRelayConfig.effectiveGatewayUrl;
    if (_customUrlController.text != next) {
      _customUrlController.text = next;
    }
  }

  @override
  void dispose() {
    _customUrlController.dispose();
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
        _MobileRelaySectionTitle(
          iconWidget: MinimalScanIcon(color: colors.primary, size: 22),
          title: strings.pairing,
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
            customUrlController: _customUrlController,
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
          SecureMeshSkillSyncCard(controller: controller),
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

class _MobileRelaySectionTitle extends StatelessWidget {
  const _MobileRelaySectionTitle({
    required this.iconWidget,
    required this.title,
  });

  final Widget iconWidget;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        iconWidget,
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
        ),
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
