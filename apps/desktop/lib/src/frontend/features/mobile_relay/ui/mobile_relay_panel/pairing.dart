import 'dart:async';

import 'package:flutter/material.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/contracts/mobile_pairing_presentation.dart';
import 'package:licoup/src/contracts/mobile_relay/mobile_relay_models.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_relay_panel/qr.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/apple_notifications.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

class MobileRelayPairingWorkspaceCard extends StatelessWidget {
  const MobileRelayPairingWorkspaceCard({
    super.key,
    required this.controller,
    required this.customUrlController,
    required this.presentation,
    required this.onGenerate,
  });

  final ClientController controller;
  final TextEditingController customUrlController;
  final MobilePairingPresentation? presentation;
  final Future<void> Function() onGenerate;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final config = controller.mobileRelayConfig;
    final inviteText = presentation?.inviteText.trim() ?? '';
    final pairingCode = presentation?.pairingCode.trim() ?? '';
    final expiresAt = config.lastPairingExpiresAt.trim().isNotEmpty
        ? config.lastPairingExpiresAt
        : (controller.mobileRelayActionResult?['expiresAt']?.toString() ?? '');
    final gateway = canonicalMobileRelayGatewayOrigin(
      config.effectiveGatewayUrl,
    );
    final gatewayConfigured =
        gateway != null && !mobileRelayGatewayIsEphemeralCustom(gateway);

    return Container(
      key: const Key('pairing-qr-workspace-card'),
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surfaceLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.line.withAlpha(90)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final info = _MobileRelayPairingInfoPane(
            controller: controller,
            customUrlController: customUrlController,
            paired: config.paired,
            pairingCode: pairingCode,
            expiresAt: expiresAt,
          );
          final qr = MobileRelayPairingQrFrame(
            inviteText: inviteText,
            busy: controller.isMobileRelayBusy,
            gatewayConfigured: gatewayConfigured,
            onGenerate: onGenerate,
          );
          if (constraints.maxWidth < 720) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                info,
                const SizedBox(height: 18),
                Align(alignment: Alignment.center, child: qr),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: info),
              const SizedBox(width: 24),
              qr,
            ],
          );
        },
      ),
    );
  }
}

class _MobileRelayPairingInfoPane extends StatelessWidget {
  const _MobileRelayPairingInfoPane({
    required this.controller,
    required this.customUrlController,
    required this.paired,
    required this.pairingCode,
    required this.expiresAt,
  });

  final ClientController controller;
  final TextEditingController customUrlController;
  final bool paired;
  final String pairingCode;
  final String expiresAt;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final config = controller.mobileRelayConfig;
    final busy = controller.isMobileRelayBusy;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          strings.gateway,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            color: colors.textMuted,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('mobile-relay-explicit-gateway-field'),
          controller: customUrlController,
          enabled: !busy,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.link_outlined),
            hintText: 'https://relay.example.com',
            suffixIcon: IconButton(
              tooltip: strings.saveGateway,
              icon: const Icon(Icons.save_outlined),
              onPressed: busy
                  ? null
                  : () => unawaited(
                      _saveGateway(controller, customUrlController),
                    ),
            ),
          ),
          onSubmitted: (_) =>
              unawaited(_saveGateway(controller, customUrlController)),
        ),
        const SizedBox(height: 16),
        MobileRelayPairingInfoRow(
          label: strings.status,
          value: paired ? strings.paired : strings.waiting,
        ),
        MobileRelayPairingInfoRow(
          label: strings.pairingId,
          value: config.pairingId,
        ),
        MobileRelayPairingInfoRow(label: strings.expires, value: expiresAt),
        if (pairingCode.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            strings.oneTimePairingCodeNotice,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colors.textMuted,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
            decoration: BoxDecoration(
              color: colors.surfaceHigh,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: colors.line.withAlpha(80)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        strings.pairingCode,
                        style: TextStyle(
                          color: colors.textMuted,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      SelectableText(
                        pairingCode,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              color: colors.primary,
                              fontWeight: FontWeight.w800,
                            ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: strings.copyPairingCode,
                  icon: const Icon(Icons.copy_outlined),
                  color: colors.primary,
                  onPressed: () => unawaited(
                    _copyPairingCode(context, controller, strings, pairingCode),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class MobileRelayPairingInfoRow extends StatelessWidget {
  const MobileRelayPairingInfoRow({
    super.key,
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final display = value.trim().isEmpty ? '-' : value.trim();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 112,
            child: Text(label, style: TextStyle(color: colors.textMuted)),
          ),
          Expanded(
            child: SelectableText(
              display,
              style: TextStyle(color: colors.text),
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _saveGateway(
  ClientController controller,
  TextEditingController customUrlController,
) {
  return controller.configureMobileRelayGateway(
    useCustomGateway: true,
    customGatewayUrl: customUrlController.text,
  );
}

Future<void> _copyPairingCode(
  BuildContext context,
  ClientController controller,
  LicoStrings strings,
  String code,
) async {
  final copied = await controller.copyMobilePairingCode(code);
  if (!copied || !context.mounted) {
    return;
  }
  ScaffoldMessenger.of(context).showSnackBar(
    appleGlassSnackBar(context: context, message: strings.pairingCodeCopied),
  );
}
