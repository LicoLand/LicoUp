import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:qr_code_dart_scan/qr_code_dart_scan.dart';

import 'package:licoup/src/frontend/shared/ui/theme.dart';

class MobilePairDeviceScanner extends StatelessWidget {
  const MobilePairDeviceScanner({super.key, required this.onDetect});

  final Future<void> Function(String value) onDetect;

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS) {
      return const _UnsupportedScannerPanel();
    }
    return QRCodeDartScanView(
      typeScan: TypeScan.live,
      formats: const [BarcodeFormat.qrCode],
      onCapture: (result) {
        final value = result.text.trim();
        if (value.isNotEmpty) {
          onDetect(value);
        }
      },
      onCameraError: (message) {
        debugPrint('Pairing QR scanner unavailable: $message');
      },
    );
  }
}

class _UnsupportedScannerPanel extends StatelessWidget {
  const _UnsupportedScannerPanel();

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return ColoredBox(
      color: colors.surfaceLow,
      child: Center(
        child: Icon(Icons.no_photography_outlined, color: colors.textMuted),
      ),
    );
  }
}
