import 'package:flutter/material.dart';

import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_flutter/presentation_flutter.dart';

import 'package:licoup/src/frontend/binding/effect_listener.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_relay_panel/pairing.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_relay_panel/scan.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_relay_panel/trust.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/secure_mesh_approval_card.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/secure_mesh_capability_card.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/secure_mesh_file_sync_card.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/platform/client_platform.dart';
import 'package:licoup/src/frontend/shared/ui/lico_pane_scaffold.dart';
import 'package:licoup/src/frontend/shared/ui/lico_toast.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_binding.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_effect.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_inputs.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_intent.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_providers.dart';

class MobileRelayPanel extends StatefulWidget {
  const MobileRelayPanel({super.key, required this.binding, this.chatChannels});

  final MobileRelayBinding binding;
  final Widget? chatChannels;

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
      child:
          AsyncRegion<MobileRelayPairingInputs, IntentSink<MobileRelayIntent>>(
            source: mobileRelayPairingInputsProvider,
            actions: widget.binding.intents,
            loading: (_, _) => const SizedBox.shrink(),
            data: (context, pairing, intents) {
              _syncStation(pairing.stationLabel);
              return _buildPanel(context, pairing, intents);
            },
          ),
    );
  }

  Widget _buildPanel(
    BuildContext context,
    MobileRelayPairingInputs pairing,
    IntentSink<MobileRelayIntent> intents,
  ) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final paired = pairing.paired;
    final mobileClient =
        pairing.mobileRuntime || isMobileClientPlatform(context);
    final busy = pairing.busy || pairing.polling;
    // The standard feature-page structure: pane title bar (移动配对 +
    // refresh) above, the pairing/trust/capability content below.
    return LicoPaneScaffold(
      title: strings.mobilePairing,
      refreshTooltip: strings.refresh,
      onRefresh: busy ? null : () => intents.send(const RefreshMobileRelay()),
      refreshing: busy,
      refreshButtonKey: const Key('mobile-relay-refresh'),
      body: ListView(
        padding: EdgeInsets.zero,
        children: [
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
              value: pairing.pairingId,
            ),
            MobileRelayPairingInfoRow(
              label: strings.expires,
              value: pairing.pairingExpiresLabel,
            ),
          ] else
            MobileRelayPairingWorkspaceCard(
              inputs: pairing,
              intents: intents,
              stationBaseUrlController: _stationBaseUrlController,
            ),
          if (paired) ...[
            AsyncRegion<MobileRelayTrustInputs, IntentSink<MobileRelayIntent>>(
              source: mobileRelayTrustInputsProvider,
              actions: intents,
              loading: (_, _) => const SizedBox.shrink(),
              data: (context, trust, _) {
                final presentation = trust.trust;
                if (presentation == null) {
                  return const SizedBox.shrink();
                }
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _MobileRelayDivider(),
                    MobileRelayTrustVerificationCard(
                      presentation: presentation,
                      colors: colors,
                    ),
                  ],
                );
              },
            ),
            const _MobileRelayDivider(),
            AsyncRegion<
              MobileRelayTransfersInputs,
              IntentSink<MobileRelayIntent>
            >(
              source: mobileRelayTransfersInputsProvider,
              actions: intents,
              loading: (_, _) => const SizedBox.shrink(),
              data: (context, transfers, _) =>
                  SecureMeshFileSyncCard(inputs: transfers, intents: intents),
            ),
            const SizedBox(height: 12),
            AsyncRegion<
              MobileRelayApprovalsInputs,
              IntentSink<MobileRelayIntent>
            >(
              source: mobileRelayApprovalsInputsProvider,
              actions: intents,
              loading: (_, _) => const SizedBox.shrink(),
              data: (context, approvals, _) => SecureMeshApprovalCard.inputs(
                inputs: approvals,
                intents: intents,
              ),
            ),
          ],
          if (widget.chatChannels != null) ...[
            const _MobileRelayDivider(),
            widget.chatChannels!,
          ],
          AsyncRegion<
            MobileRelayCapabilitiesInputs,
            IntentSink<MobileRelayIntent>
          >(
            source: mobileRelayCapabilitiesInputsProvider,
            actions: intents,
            loading: (_, _) => const SizedBox.shrink(),
            data: (context, capabilities, _) {
              final projection = capabilities.capabilities;
              if (projection == null) return const SizedBox.shrink();
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _MobileRelayDivider(),
                  SecureMeshCapabilityCard(projection: projection),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  void _syncStation(String value) {
    if (_stationBaseUrlController.text != value) {
      _stationBaseUrlController.text = value;
    }
  }

  void _onEffect(MobileRelayEffect effect) {
    if (!mounted) return;
    final (message, kind) = switch (effect) {
      RelayPairingCodeCopied() => (
        LicoStrings.of(context).pairingCodeCopied,
        LicoToastKind.success,
      ),
      RelayActionRejected(:final reasonCode) => (
        reasonCode,
        LicoToastKind.error,
      ),
      RelayPairingReady() || RelayPairingClaimed() => ('', LicoToastKind.info),
    };
    if (message.isEmpty) return;
    showLicoToast(context, message: message, kind: kind);
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
