import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/contracts/mobile_relay/mobile_relay_models.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/shared/platform/client_platform.dart';
import 'package:flutter_client/src/frontend/shared/ui/apple_notifications.dart';
import 'package:flutter_client/src/frontend/shared/ui/minimal_scan_icon.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';
import 'package:flutter_client/src/frontend/features/mobile_relay/ui/secure_mesh_capability_card.dart';
import 'package:flutter_client/src/frontend/features/mobile_relay/ui/secure_mesh_file_sync_card.dart';
import 'package:flutter_client/src/frontend/features/mobile_relay/ui/secure_mesh_skill_sync_card.dart';
import 'package:flutter_client/src/frontend/features/mobile_relay/ui/secure_mesh_approval_card.dart';

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
      text: controller.mobileRelayConfig.customGatewayUrl,
    );
  }

  @override
  void didUpdateWidget(covariant MobileRelayPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = controller.mobileRelayConfig.customGatewayUrl;
    if (_customUrlController.text != next) {
      _customUrlController.text = next;
    }
  }

  @override
  void dispose() {
    _customUrlController.dispose();
    super.dispose();
  }

  Future<void> _generatePairingCode() async {
    await controller.createMobilePairing();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final config = controller.mobileRelayConfig;
    final paired = config.paired;
    final mobileClient = isMobileClientPlatform(context);
    final presentation = controller.mobilePairingPresentation;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        if (mobileClient) ...[
          _SectionTitle(
            iconWidget: MinimalScanIcon(color: colors.primary, size: 22),
            title: strings.pairing,
          ),
          const SizedBox(height: 12),
          _ScanPairingPrompt(colors: colors, label: strings.scanPairingPrompt),
          const SizedBox(height: 12),
          _InfoRow(
            label: strings.status,
            value: paired ? strings.paired : strings.waiting,
          ),
          _InfoRow(label: strings.pairingId, value: config.pairingId),
          _InfoRow(label: strings.expires, value: config.lastPairingExpiresAt),
        ] else ...[
          _SectionTitle(
            iconWidget: MinimalScanIcon(color: colors.primary, size: 22),
            title: strings.pairing,
          ),
          const SizedBox(height: 12),
          _PairingQrWorkspaceCard(
            controller: controller,
            customUrlController: _customUrlController,
            presentation: presentation,
            onGenerate: _generatePairingCode,
          ),
        ],
        if (paired && config.trustPresentation != null) ...[
          const _Divider(),
          _TrustVerificationCard(
            presentation: config.trustPresentation!,
            colors: colors,
          ),
        ],
        if (paired) ...[
          const _Divider(),
          SecureMeshFileSyncCard(controller: controller),
          const SizedBox(height: 12),
          SecureMeshSkillSyncCard(controller: controller),
          const SizedBox(height: 12),
          SecureMeshApprovalCard(controller: controller),
        ],
        if (controller.secureMeshCapabilityProjection != null) ...[
          const _Divider(),
          SecureMeshCapabilityCard(
            projection: controller.secureMeshCapabilityProjection!,
          ),
        ],
      ],
    );
  }
}

class _PairingQrWorkspaceCard extends StatelessWidget {
  const _PairingQrWorkspaceCard({
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
    final paired = config.paired;
    final busy = controller.isMobileRelayBusy;
    final inviteText = presentation?.inviteText.trim() ?? '';
    final pairingCode = presentation?.pairingCode.trim() ?? '';
    final expiresAt = config.lastPairingExpiresAt.trim().isNotEmpty
        ? config.lastPairingExpiresAt
        : (controller.mobileRelayActionResult?['expiresAt']?.toString() ?? '');

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
          final stacked = constraints.maxWidth < 720;
          final left = _PairingQrInfoPane(
            controller: controller,
            customUrlController: customUrlController,
            paired: paired,
            pairingCode: pairingCode,
            expiresAt: expiresAt,
          );
          final right = _PairingQrFramePane(
            inviteText: inviteText,
            busy: busy,
            onGenerate: onGenerate,
          );
          if (stacked) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                left,
                const SizedBox(height: 18),
                Align(alignment: Alignment.center, child: right),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: left),
              const SizedBox(width: 24),
              right,
            ],
          );
        },
      ),
    );
  }
}

class _PairingQrInfoPane extends StatelessWidget {
  const _PairingQrInfoPane({
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
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Text(
                strings.gateway,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: colors.textMuted,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Flexible(
              child: Align(
                alignment: Alignment.centerRight,
                child: SegmentedButton<bool>(
                  style: ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  segments: [
                    ButtonSegment(
                      value: false,
                      label: Text(strings.licoArcGateway),
                      icon: const Icon(Icons.check_rounded, size: 16),
                    ),
                    ButtonSegment(
                      value: true,
                      label: Text(strings.customGateway),
                      icon: const Icon(Icons.cloud_outlined, size: 16),
                    ),
                  ],
                  selected: {config.useCustomGateway},
                  onSelectionChanged: busy
                      ? null
                      : (selection) {
                          unawaited(
                            controller.configureMobileRelayGateway(
                              useCustomGateway: selection.first,
                              customGatewayUrl: customUrlController.text,
                            ),
                          );
                        },
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (config.useCustomGateway)
          TextField(
            controller: customUrlController,
            enabled: !busy,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.link_outlined),
              suffixIcon: IconButton(
                tooltip: strings.saveGateway,
                icon: const Icon(Icons.save_outlined),
                onPressed: busy
                    ? null
                    : () {
                        unawaited(
                          controller.configureMobileRelayGateway(
                            useCustomGateway: config.useCustomGateway,
                            customGatewayUrl: customUrlController.text,
                          ),
                        );
                      },
              ),
            ),
            onSubmitted: (_) {
              unawaited(
                controller.configureMobileRelayGateway(
                  useCustomGateway: config.useCustomGateway,
                  customGatewayUrl: customUrlController.text,
                ),
              );
            },
          )
        else
          _LockedGatewayField(
            value: config.effectiveGatewayUrl,
            tooltip: strings.gatewayLocked,
          ),
        const SizedBox(height: 16),
        _InfoRow(
          label: strings.status,
          value: paired ? strings.paired : strings.waiting,
        ),
        _InfoRow(label: strings.pairingId, value: config.pairingId),
        _InfoRow(label: strings.expires, value: expiresAt),
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

class _PairingQrFramePane extends StatelessWidget {
  const _PairingQrFramePane({
    required this.inviteText,
    required this.busy,
    required this.onGenerate,
  });

  final String inviteText;
  final bool busy;
  final Future<void> Function() onGenerate;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final hasQr = inviteText.isNotEmpty;

    // Placeholder uses a fixed carbon charcoal so it stays distinct from the
    // pure-black shell without inheriting warm brand-muted yellow fills.
    const placeholderFill = Color(0xFF1E1E22);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            key: const Key('pairing-qr-frame'),
            onTap: busy ? null : () => unawaited(onGenerate()),
            borderRadius: BorderRadius.circular(12),
            child: Ink(
              width: 220,
              height: 220,
              decoration: BoxDecoration(
                color: hasQr ? Colors.white : placeholderFill,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: hasQr
                      ? colors.line.withAlpha(40)
                      : const Color(0xFF3A3A40),
                ),
              ),
              child: hasQr
                  ? Padding(
                      padding: const EdgeInsets.all(14),
                      child: QrImageView(
                        data: inviteText,
                        version: QrVersions.auto,
                        errorCorrectionLevel: QrErrorCorrectLevel.M,
                        padding: EdgeInsets.zero,
                        backgroundColor: Colors.white,
                      ),
                    )
                  : Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (busy)
                          const SizedBox.square(
                            dimension: 28,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        else
                          Icon(
                            Icons.qr_code_2_rounded,
                            size: 96,
                            color: colors.textMuted.withAlpha(160),
                          ),
                        const SizedBox(height: 14),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Text(
                            strings.tapToGeneratePairingQr,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  color: colors.textMuted,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
        if (hasQr) ...[
          const SizedBox(height: 10),
          SizedBox(
            width: 220,
            child: Text(
              strings.scanQrToPairPhone,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.textMuted,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _TrustVerificationCard extends StatelessWidget {
  const _TrustVerificationCard({
    required this.presentation,
    required this.colors,
  });

  final MobileRelayTrustPresentation presentation;
  final LicoThemeColors colors;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final statusColor = switch (presentation.trustState) {
      'verified' when presentation.verified => colors.success,
      'key_changed' || 'revoked' => colors.error,
      _ => colors.warning,
    };
    final statusText = switch (presentation.trustState) {
      'verified' when presentation.verified => strings.trustVerified,
      'key_changed' => strings.trustKeyChanged,
      'revoked' => strings.trustRevoked,
      _ => strings.trustUnverified,
    };
    return Container(
      key: const Key('secure-mesh-trust-verification-card'),
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surfaceHigh,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: statusColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                presentation.verified
                    ? Icons.verified_user_outlined
                    : Icons.gpp_bad_outlined,
                color: statusColor,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  strings.deviceTrustVerification,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            statusText,
            key: const Key('secure-mesh-trust-state'),
            style: TextStyle(color: statusColor, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            strings.compareSafetyNumber,
            style: TextStyle(color: colors.textMuted),
          ),
          if (presentation.safetyNumberGroups.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(
              strings.safetyNumber,
              style: TextStyle(color: colors.textMuted),
            ),
            const SizedBox(height: 5),
            SelectableText(
              presentation.safetyNumber,
              key: const Key('secure-mesh-60-digit-safety-number'),
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: colors.text,
                fontFeatures: const [FontFeature.tabularFigures()],
                fontWeight: FontWeight.w800,
                height: 1.5,
              ),
            ),
          ],
          const SizedBox(height: 12),
          _TrustFingerprint(
            label: strings.localFingerprint,
            value: presentation.localFingerprint,
            colors: colors,
          ),
          const SizedBox(height: 8),
          _TrustFingerprint(
            label: strings.peerFingerprint,
            value: presentation.peerFingerprint,
            colors: colors,
          ),
          const SizedBox(height: 8),
          _InfoRow(
            label: strings.verificationMethod,
            value: strings.displayStatusValue(presentation.verificationMethod),
          ),
          if (presentation.qrPayload.isNotEmpty) ...[
            const SizedBox(height: 14),
            Center(
              child: Container(
                width: 176,
                height: 176,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: QrImageView(
                  data: presentation.qrPayload,
                  version: QrVersions.auto,
                  errorCorrectionLevel: QrErrorCorrectLevel.M,
                  padding: EdgeInsets.zero,
                  backgroundColor: Colors.white,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _TrustFingerprint extends StatelessWidget {
  const _TrustFingerprint({
    required this.label,
    required this.value,
    required this.colors,
  });

  final String label;
  final String value;
  final LicoThemeColors colors;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: colors.textMuted)),
        const SizedBox(height: 3),
        SelectableText(
          value,
          style: TextStyle(color: colors.text, fontFamily: 'monospace'),
        ),
      ],
    );
  }
}

class _LockedGatewayField extends StatelessWidget {
  const _LockedGatewayField({required this.value, required this.tooltip});

  final String value;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final display = value.trim().isEmpty ? '-' : value.trim();
    return TextFormField(
      key: ValueKey(display),
      initialValue: display,
      readOnly: true,
      enableInteractiveSelection: true,
      decoration: InputDecoration(
        prefixIcon: const Icon(Icons.link_outlined),
        suffixIcon: Tooltip(
          message: tooltip,
          child: Icon(Icons.lock_outline, color: colors.textMuted),
        ),
      ),
    );
  }
}

class _ScanPairingPrompt extends StatelessWidget {
  const _ScanPairingPrompt({required this.colors, required this.label});

  final LicoThemeColors colors;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surfaceHigh,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.line),
      ),
      child: Row(
        children: [
          MinimalScanIcon(color: colors.primary, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colors.text,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
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

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({this.icon, this.iconWidget, required this.title})
    : assert(icon != null || iconWidget != null);

  final IconData? icon;
  final Widget? iconWidget;
  final String title;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Row(
      children: [
        iconWidget ?? Icon(icon, color: colors.primary),
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

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

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

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: Divider(height: 1, color: colors.line),
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
