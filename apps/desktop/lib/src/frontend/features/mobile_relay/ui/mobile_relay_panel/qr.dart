import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

class MobileRelayPairingQrFrame extends StatelessWidget {
  const MobileRelayPairingQrFrame({
    super.key,
    required this.inviteText,
    required this.busy,
    required this.gatewayConfigured,
    required this.onGenerate,
  });

  final String inviteText;
  final bool busy;
  final bool gatewayConfigured;
  final Future<void> Function() onGenerate;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final hasQr = inviteText.isNotEmpty;

    // Fixed carbon charcoal keeps the placeholder distinct from the black
    // shell without inheriting a warm brand-muted fill.
    const placeholderFill = Color(0xFF1E1E22);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            key: const Key('pairing-qr-frame'),
            onTap: busy || !gatewayConfigured
                ? null
                : () => unawaited(onGenerate()),
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
