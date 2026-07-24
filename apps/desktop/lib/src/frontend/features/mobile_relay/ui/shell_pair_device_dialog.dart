import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/minimal_scan_icon.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

typedef PairDeviceScannerPreviewBuilder =
    Widget Function(
      BuildContext context,
      Future<void> Function(BarcodeCapture capture) onDetect,
    );

class PairDeviceDialog extends StatefulWidget {
  const PairDeviceDialog({
    super.key,
    required this.onClaim,
    this.scannerPreviewBuilder,
    this.scannerPreviewOverride,
  });

  final Future<void> Function(String value) onClaim;
  final PairDeviceScannerPreviewBuilder? scannerPreviewBuilder;
  final Widget? scannerPreviewOverride;

  @override
  State<PairDeviceDialog> createState() => _PairDeviceDialogState();
}

class _PairDeviceDialogState extends State<PairDeviceDialog> {
  late final MobileScannerController _scannerController;
  final TextEditingController _tokenController = TextEditingController();
  bool _submitting = false;
  bool _scanStatusError = false;
  String _scanStatus = '';

  @override
  void initState() {
    super.initState();
    _scannerController = MobileScannerController(
      detectionSpeed: DetectionSpeed.noDuplicates,
      formats: const [BarcodeFormat.qrCode],
      autoZoom: true,
    );
    _tokenController.addListener(_handleTokenChanged);
  }

  @override
  void dispose() {
    _tokenController
      ..removeListener(_handleTokenChanged)
      ..dispose();
    unawaited(_scannerController.dispose());
    super.dispose();
  }

  void _handleTokenChanged() {
    setState(() {});
  }

  bool get _usesRealScanner =>
      widget.scannerPreviewBuilder == null &&
      widget.scannerPreviewOverride == null;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final mediaSize = MediaQuery.sizeOf(context);
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    final availableDialogHeight = math.max(
      280.0,
      mediaSize.height - keyboardInset - 48.0,
    );
    final widthBoundScanSize = (mediaSize.width - 72)
        .clamp(220.0, 312.0)
        .toDouble();
    final canSubmitToken =
        _tokenController.text.trim().isNotEmpty && !_submitting;
    final scanCaption = _scanStatus.isEmpty ? strings.scanQrCode : _scanStatus;
    final scanCaptionColor = _scanStatusError
        ? colors.error
        : (_submitting ? colors.primary : Colors.white);
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      backgroundColor: colors.background,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 430,
          maxHeight: availableDialogHeight,
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final heightBoundScanSize = (constraints.maxHeight - 158.0)
                .clamp(170.0, 312.0)
                .toDouble();
            final scanSize = math.min(widthBoundScanSize, heightBoundScanSize);
            return SingleChildScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 14, 10, 10),
                    child: Row(
                      children: [
                        Icon(Icons.add_link_outlined, color: colors.primary),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            strings.pairDevice,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                        ),
                        IconButton(
                          tooltip: strings.close,
                          icon: const Icon(Icons.close_outlined),
                          onPressed: _submitting
                              ? null
                              : () => Navigator.of(context).pop(),
                        ),
                      ],
                    ),
                  ),
                  Center(
                    child: SizedBox(
                      width: scanSize,
                      height: scanSize,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            widget.scannerPreviewBuilder?.call(
                                  context,
                                  _handleCapture,
                                ) ??
                                widget.scannerPreviewOverride ??
                                MobileScanner(
                                  controller: _scannerController,
                                  fit: BoxFit.cover,
                                  onDetect: _handleCapture,
                                  errorBuilder: (context, error) =>
                                      _ScannerErrorPanel(
                                        message:
                                            error.errorDetails?.message ??
                                            error.toString(),
                                      ),
                                ),
                            IgnorePointer(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: colors.primary,
                                    width: 2,
                                  ),
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                            ),
                            Align(
                              alignment: Alignment.bottomCenter,
                              child: Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 10,
                                ),
                                color: Colors.black.withValues(alpha: 0.54),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    const MinimalScanIcon(
                                      color: Colors.white,
                                      size: 18,
                                    ),
                                    const SizedBox(width: 8),
                                    Flexible(
                                      child: Text(
                                        scanCaption,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: scanCaptionColor,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            if (_submitting)
                              ColoredBox(
                                color: Colors.black.withValues(alpha: 0.32),
                                child: const Center(
                                  child: CircularProgressIndicator(),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: colors.surfaceLow,
                        border: Border.all(color: colors.line),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Row(
                        children: [
                          const SizedBox(width: 14),
                          Icon(
                            Icons.vpn_key_outlined,
                            color: colors.textMuted,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: _tokenController,
                              enabled: !_submitting,
                              minLines: 1,
                              maxLines: 1,
                              textInputAction: TextInputAction.done,
                              onSubmitted: (_) => _submitToken(),
                              decoration: InputDecoration(
                                hintText: strings.pairingInviteToken,
                                border: InputBorder.none,
                                enabledBorder: InputBorder.none,
                                focusedBorder: InputBorder.none,
                                disabledBorder: InputBorder.none,
                                contentPadding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                                isDense: true,
                              ),
                            ),
                          ),
                          Container(width: 1, height: 28, color: colors.line),
                          SizedBox(
                            width: 48,
                            height: 44,
                            child: IconButton(
                              tooltip: strings.pairingInviteToken,
                              onPressed: canSubmitToken ? _submitToken : null,
                              icon: _submitting
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.check_outlined, size: 19),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _handleCapture(BarcodeCapture capture) async {
    if (_submitting) {
      return;
    }
    for (final barcode in capture.barcodes) {
      final raw = _barcodeText(barcode);
      if (raw.isNotEmpty) {
        await _submit(raw);
        return;
      }
    }
  }

  Future<void> _submitToken() async {
    await _submit(_tokenController.text);
  }

  Future<void> _submit(String value) async {
    final trimmed = value.trim();
    if (trimmed.isEmpty || _submitting) {
      return;
    }
    setState(() {
      _submitting = true;
      _scanStatusError = false;
      _scanStatus = LicoStrings.of(context).pairingQrDetected;
    });
    await _stopScannerIfActive();
    try {
      await widget.onClaim(trimmed);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _submitting = false;
        _scanStatusError = true;
        _scanStatus = LicoStrings.of(context).pairingScanFailed;
      });
      await _startScannerIfActive();
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _scanStatusError = false;
      _scanStatus = LicoStrings.of(context).pairingScanSuccess;
    });
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (!mounted) {
      return;
    }
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
    }
  }

  Future<void> _stopScannerIfActive() async {
    if (!_usesRealScanner) {
      return;
    }
    try {
      await _scannerController.stop();
    } catch (error) {
      debugPrint('Failed to stop pairing QR scanner: $error');
    }
  }

  Future<void> _startScannerIfActive() async {
    if (!_usesRealScanner) {
      return;
    }
    try {
      await _scannerController.start();
    } catch (error) {
      debugPrint('Failed to restart pairing QR scanner: $error');
    }
  }
}

String _barcodeText(Barcode barcode) {
  for (final candidate in [
    barcode.rawValue,
    barcode.displayValue,
    _decodedBarcodeBytes(barcode.rawDecodedBytes),
  ]) {
    final value = candidate?.trim() ?? '';
    if (value.isNotEmpty) {
      return value;
    }
  }
  return '';
}

String? _decodedBarcodeBytes(BarcodeBytes? bytes) {
  if (bytes is DecodedBarcodeBytes) {
    return utf8.decode(bytes.bytes, allowMalformed: true);
  }
  if (bytes is DecodedVisionBarcodeBytes) {
    return utf8.decode(bytes.bytes ?? bytes.rawBytes, allowMalformed: true);
  }
  return null;
}

class _ScannerErrorPanel extends StatelessWidget {
  const _ScannerErrorPanel({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return ColoredBox(
      color: colors.surfaceLow,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.no_photography_outlined, color: colors.error),
              const SizedBox(height: 10),
              Text(
                message,
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
