import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/binding/effect_listener.dart';
import 'package:licoup/src/frontend/binding/projection_builder.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_relay_panel/pairing.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_relay_panel/scan.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_relay_panel/trust.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/secure_mesh_approval_card.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/secure_mesh_capability_card.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/secure_mesh_file_sync_card.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/platform/client_platform.dart';
import 'package:licoup/src/frontend/shared/ui/apple_notifications.dart';
import 'package:licoup/src/frontend/shared/ui/lico_section_header.dart';
import 'package:licoup/src/frontend/shared/ui/minimal_scan_icon.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_binding.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_effect.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_projection.dart';

class MobileRelayPanel extends StatefulWidget {
  const MobileRelayPanel({super.key, required this.binding});

  final MobileRelayBinding binding;

  @override
  State<MobileRelayPanel> createState() => _MobileRelayPanelState();
}

class _MobileRelayPanelState extends State<MobileRelayPanel> {
  late final TextEditingController _stationBaseUrlController;

  @override
  void initState() {
    super.initState();
    _stationBaseUrlController = TextEditingController(
      text: widget.binding.projection.current.stationLabel,
    );
  }

  @override
  void didUpdateWidget(covariant MobileRelayPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.binding, widget.binding)) {
      _syncStation(widget.binding.projection.current.stationLabel);
    }
  }

  @override
  void dispose() {
    _stationBaseUrlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return EffectListener<MobileRelayEffect>(
      source: widget.binding.effects,
      onEffect: _onEffect,
      child: ProjectionBuilder<MobileRelayProjection, MobileRelayProjection>(
        source: widget.binding.projection,
        select: (projection) => projection,
        builder: (context, projection) {
          _syncStation(projection.stationLabel);
          return _buildProjection(context, projection);
        },
      ),
    );
  }

  Widget _buildProjection(
    BuildContext context,
    MobileRelayProjection projection,
  ) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final paired = projection.paired;
    final mobileClient =
        projection.mobileRuntime || isMobileClientPlatform(context);
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
            value: projection.pairingId,
          ),
          MobileRelayPairingInfoRow(
            label: strings.expires,
            value: projection.pairingExpiresLabel,
          ),
        ] else
          MobileRelayPairingWorkspaceCard(
            projection: projection,
            intents: widget.binding.intents,
            stationBaseUrlController: _stationBaseUrlController,
          ),
        if (paired && projection.trust != null) ...[
          const _MobileRelayDivider(),
          MobileRelayTrustVerificationCard(
            presentation: projection.trust!,
            colors: colors,
          ),
        ],
        if (paired) ...[
          const _MobileRelayDivider(),
          SecureMeshFileSyncCard(
            projection: projection,
            intents: widget.binding.intents,
          ),
          const SizedBox(height: 12),
          SecureMeshApprovalCard(
            projection: projection,
            intents: widget.binding.intents,
          ),
        ],
        if (projection.secureMeshCapabilities != null) ...[
          const _MobileRelayDivider(),
          SecureMeshCapabilityCard(
            projection: projection.secureMeshCapabilities!,
          ),
        ],
      ],
    );
  }

  void _syncStation(String value) {
    if (_stationBaseUrlController.text != value) {
      _stationBaseUrlController.text = value;
    }
  }

  void _onEffect(MobileRelayEffect effect) {
    if (!mounted) return;
    final message = switch (effect) {
      RelayPairingCodeCopied() => LicoStrings.of(context).pairingCodeCopied,
      RelayActionRejected(:final reasonCode) => reasonCode,
      RelayPairingReady() || RelayPairingClaimed() => '',
    };
    if (message.isEmpty) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(appleGlassSnackBar(context: context, message: message));
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
  MobileRelayBinding binding,
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
            child: MobileRelayPanel(binding: binding),
          ),
        ),
      );
    },
  );
}
