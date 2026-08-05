import 'dart:io';

import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Read-only view of the bound Lico Agent plan file under portable client data.
class LicoPlanDocumentPanel extends StatefulWidget {
  const LicoPlanDocumentPanel({
    super.key,
    required this.planPath,
    this.refreshToken = 0,
  });

  final String planPath;
  final int refreshToken;

  @override
  State<LicoPlanDocumentPanel> createState() => _LicoPlanDocumentPanelState();
}

class _LicoPlanDocumentPanelState extends State<LicoPlanDocumentPanel> {
  String _content = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void didUpdateWidget(covariant LicoPlanDocumentPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.planPath != widget.planPath ||
        oldWidget.refreshToken != widget.refreshToken) {
      _reload();
    }
  }

  Future<void> _reload() async {
    final path = widget.planPath.trim();
    if (path.isEmpty) {
      setState(() {
        _content = '';
        _error = null;
      });
      return;
    }
    try {
      final file = File(path);
      final text = await file.exists() ? await file.readAsString() : '';
      if (!mounted) return;
      setState(() {
        _content = text;
        _error = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _content = '';
        _error = 'plan_read_failed';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Material(
      color: colors.surfaceLow.withAlpha(colors.isDark ? 160 : 220),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    strings.planDocumentTitle,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: colors.text,
                    ),
                  ),
                ),
                IconButton(
                  key: const Key('lico-plan-doc-refresh'),
                  tooltip: strings.refresh,
                  onPressed: _reload,
                  icon: const Icon(Icons.refresh, size: 18),
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: SelectableText(
                _error != null
                    ? strings.planDocumentUnavailable
                    : (_content.trim().isEmpty
                          ? strings.planDocumentEmpty
                          : _content),
                style: TextStyle(
                  color: _error != null ? colors.textMuted : colors.text,
                  fontSize: 13,
                  height: 1.45,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
