import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:flutter_client/src/contracts/mobile_relay/mobile_relay_models.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

class MobileRelayTrustVerificationCard extends StatelessWidget {
  const MobileRelayTrustVerificationCard({
    super.key,
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
          _MobileRelayTrustFingerprint(
            label: strings.localFingerprint,
            value: presentation.localFingerprint,
            colors: colors,
          ),
          const SizedBox(height: 8),
          _MobileRelayTrustFingerprint(
            label: strings.peerFingerprint,
            value: presentation.peerFingerprint,
            colors: colors,
          ),
          const SizedBox(height: 8),
          _MobileRelayTrustInfoRow(
            label: strings.verificationMethod,
            value: strings.displayStatusValue(presentation.verificationMethod),
            colors: colors,
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

class _MobileRelayTrustFingerprint extends StatelessWidget {
  const _MobileRelayTrustFingerprint({
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

class _MobileRelayTrustInfoRow extends StatelessWidget {
  const _MobileRelayTrustInfoRow({
    required this.label,
    required this.value,
    required this.colors,
  });

  final String label;
  final String value;
  final LicoThemeColors colors;

  @override
  Widget build(BuildContext context) {
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
