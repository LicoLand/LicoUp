import 'dart:async';

import 'package:flutter/material.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Settings card: login autostart for the desktop client and background helpers.
final class StartupAutostartCard extends StatefulWidget {
  const StartupAutostartCard({super.key, required this.controller});

  final ClientController controller;

  @override
  State<StartupAutostartCard> createState() => _StartupAutostartCardState();
}

final class _StartupAutostartCardState extends State<StartupAutostartCard> {
  bool _loading = true;
  bool _busy = false;
  bool _supported = false;
  bool _desktopEnabled = false;
  bool _desktopSilent = false;
  bool _gatewayEnabled = false;
  bool _mcpEnabled = false;
  String? _message;
  bool _messageIsError = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    try {
      final payload = await widget.controller.agentService.runCli(const [
        'autostart',
        'status',
      ]);
      if (!mounted) return;
      final desktop = payload['desktop'];
      final gateway = payload['gateway'];
      final mcp = payload['mcp'];
      setState(() {
        _supported = payload['supported'] == true;
        _desktopEnabled = desktop is Map && desktop['enabled'] == true;
        _desktopSilent = desktop is Map && desktop['silent'] == true;
        _gatewayEnabled = gateway is Map && gateway['enabled'] == true;
        _mcpEnabled = mcp is Map && mcp['enabled'] == true;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _supported = false;
        _loading = false;
        _messageIsError = true;
        _message = LicoStrings.of(context).startupAutostartLoadFailed;
      });
    }
  }

  Future<void> _set({
    required String component,
    required bool enabled,
    bool? silent,
  }) async {
    if (_busy || !_supported) return;
    final strings = LicoStrings.of(context);
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final args = <String>[
        'autostart',
        'set',
        '--component',
        component,
        '--enabled',
        enabled ? 'true' : 'false',
      ];
      if (component == 'desktop' && silent != null) {
        args.addAll(['--silent', silent ? 'true' : 'false']);
      }
      if (component == 'gateway') {
        final port = widget.controller.llmGatewayLifecycleController.port;
        args.addAll(['--port', '$port']);
      }
      final payload = await widget.controller.agentService.runCli(args);
      if (!mounted) return;
      final desktop = payload['desktop'];
      final gateway = payload['gateway'];
      final mcp = payload['mcp'];
      setState(() {
        _supported = payload['supported'] != false;
        _desktopEnabled = desktop is Map && desktop['enabled'] == true;
        _desktopSilent = desktop is Map && desktop['silent'] == true;
        _gatewayEnabled = gateway is Map && gateway['enabled'] == true;
        _mcpEnabled = mcp is Map && mcp['enabled'] == true;
        _messageIsError = false;
        _message = strings.startupAutostartSaved;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _messageIsError = true;
        _message = _supported
            ? strings.startupAutostartSaveFailed
            : strings.startupAutostartUnsupported;
      });
      await _refresh();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Padding(
      key: const Key('startup-autostart-card'),
      padding: const EdgeInsets.fromLTRB(
        LicoContentSpacing.item,
        LicoContentSpacing.compact,
        LicoContentSpacing.item,
        LicoContentSpacing.item,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.rocket_launch_outlined,
                color: colors.textSecondary,
                size: 18,
              ),
              const SizedBox(width: LicoContentSpacing.compact),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      strings.startupAutostartTitle,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: colors.text,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: LicoContentSpacing.inline / 2),
                    Text(
                      strings.startupAutostartHint,
                      style: TextStyle(fontSize: 11, color: colors.textMuted),
                    ),
                  ],
                ),
              ),
              if (_loading || _busy)
                const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          if (_message != null) ...[
            const SizedBox(height: 10),
            Text(
              _message!,
              style: TextStyle(
                color: _messageIsError ? colors.error : colors.textMuted,
                fontSize: 12,
              ),
            ),
          ] else if (!_loading && !_supported) ...[
            const SizedBox(height: 10),
            Text(
              strings.startupAutostartUnsupported,
              style: TextStyle(color: colors.textMuted, fontSize: 12),
            ),
          ],
          const SizedBox(height: LicoContentSpacing.item),
          _SectionLabel(label: strings.startupDesktopClientSection),
          SwitchListTile.adaptive(
            key: const Key('startup-desktop-autostart'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(strings.startupDesktopClientAutostart),
            value: _desktopEnabled,
            onChanged: !_supported || _busy || _loading
                ? null
                : (value) => unawaited(
                    _set(
                      component: 'desktop',
                      enabled: value,
                      silent: _desktopSilent,
                    ),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 12),
            child: SwitchListTile.adaptive(
              key: const Key('startup-desktop-silent'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(strings.startupSilentStart),
              subtitle: Text(
                strings.startupSilentStartHint,
                style: TextStyle(color: colors.textMuted, fontSize: 11),
              ),
              value: _desktopSilent,
              onChanged: !_supported || !_desktopEnabled || _busy || _loading
                  ? null
                  : (value) => unawaited(
                      _set(component: 'desktop', enabled: true, silent: value),
                    ),
            ),
          ),
          const SizedBox(height: LicoContentSpacing.item),
          _SectionLabel(label: strings.startupBackgroundSection),
          SwitchListTile.adaptive(
            key: const Key('startup-gateway-autostart'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('LLM Gateway'),
            subtitle: Text(
              strings.startupGatewayHint,
              style: TextStyle(color: colors.textMuted, fontSize: 11),
            ),
            value: _gatewayEnabled,
            onChanged: !_supported || _busy || _loading
                ? null
                : (value) =>
                      unawaited(_set(component: 'gateway', enabled: value)),
          ),
          SwitchListTile.adaptive(
            key: const Key('startup-mcp-autostart'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(strings.startupLocalMcpServices),
            subtitle: Text(
              strings.startupLocalMcpHint,
              style: TextStyle(color: colors.textMuted, fontSize: 11),
            ),
            value: _mcpEnabled,
            onChanged: !_supported || _busy || _loading
                ? null
                : (value) => unawaited(_set(component: 'mcp', enabled: value)),
          ),
        ],
      ),
    );
  }
}

final class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          color: colors.textMuted,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.7,
        ),
      ),
    );
  }
}
