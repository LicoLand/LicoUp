part of 'package:flutter_client/src/frontend/features/mcp_plugins/ui/mcp_plugins_panel.dart';

class _McpPluginsEmptyState extends StatelessWidget {
  const _McpPluginsEmptyState();

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          strings.scanTargetsBeforeManagingMcp,
          textAlign: TextAlign.center,
          style: TextStyle(color: colors.textMuted),
        ),
      ),
    );
  }
}

class _AgentPluginCard extends StatefulWidget {
  const _AgentPluginCard({
    required this.target,
    required this.mcpStatus,
    required this.busy,
    required this.onConfigure,
  });

  final TargetCandidate target;
  final Map<String, dynamic>? mcpStatus;
  final bool busy;
  final VoidCallback onConfigure;

  @override
  State<_AgentPluginCard> createState() => _AgentPluginCardState();
}

class _AgentPluginCardState extends State<_AgentPluginCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final target = widget.target;
    final rawMcpStatus = _statusLabelFor(target, widget.mcpStatus);
    final statusTone = _statusTone(target, rawMcpStatus);
    final badgeLabel = target.configured
        ? strings.configured
        : strings.notConfigured;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        key: Key('mcp-plugin-card-${target.target}'),
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        decoration: BoxDecoration(
          color: colors.surfaceLow.withAlpha(_hovered ? 220 : 170),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: colors.line.withAlpha(_hovered ? 120 : 80)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Stack(
                  alignment: Alignment.center,
                  children: [
                    AgentBrandIcon(
                      target: target,
                      detected: target.status != 'not-detected',
                      selected: target.configured,
                      size: 40,
                      iconSize: 26,
                    ),
                    if (widget.busy)
                      const SizedBox(
                        width: 40,
                        height: 40,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                  ],
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        target.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.text,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      _StatusBadge(
                        label: badgeLabel,
                        tone: target.configured
                            ? _PluginStatusTone.ok
                            : statusTone,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Expanded(
              child: Text(
                strings.agentPluginCardDescription(target.label),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.textMuted,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                  height: 1.4,
                ),
              ),
            ),
            _ConfigureButton(
              label: strings.configurePlugins,
              onPressed: widget.busy ? null : widget.onConfigure,
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.label, required this.tone});

  final String label;
  final _PluginStatusTone tone;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final color = switch (tone) {
      _PluginStatusTone.ok => Colors.green.shade500,
      _PluginStatusTone.warning => colors.warning,
      _PluginStatusTone.error => colors.error,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withAlpha(28),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withAlpha(70)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            tone == _PluginStatusTone.ok
                ? Icons.check_rounded
                : Icons.close_rounded,
            size: 12,
            color: color,
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _ConfigureButton extends StatelessWidget {
  const _ConfigureButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final enabled = onPressed != null;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: const Key('mcp-plugin-configure-button'),
        onTap: onPressed,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: enabled ? colors.text : colors.textMuted,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.arrow_forward_rounded,
                size: 15,
                color: enabled ? colors.text : colors.textMuted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AgentPluginConfigDialog extends StatelessWidget {
  const _AgentPluginConfigDialog({
    required this.controller,
    required this.targetId,
  });

  final ClientController controller;
  final String targetId;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        TargetCandidate? target;
        for (final entry in controller.scannedTargets) {
          if (entry.id == targetId) {
            target = entry;
            break;
          }
        }
        if (target == null) {
          return const SizedBox.shrink();
        }
        return Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 24,
            vertical: 28,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: _AgentPluginConfigCard(
              controller: controller,
              target: target,
            ),
          ),
        );
      },
    );
  }
}

class _AgentPluginConfigCard extends StatelessWidget {
  const _AgentPluginConfigCard({
    required this.controller,
    required this.target,
  });

  final ClientController controller;
  final TargetCandidate target;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final configPath = _configPathFor(target);
    final mcpStatus = controller.mcpPluginStatuses[target.target];
    final busy = controller.isMcpPluginBusy(target.target);
    final mcpAction = _mcpActionKindFor(target);
    final rawMcpStatusLabel = _statusLabelFor(target, mcpStatus);
    final mcpStatusLabel = rawMcpStatusLabel == 'unknown'
        ? strings.unknown
        : strings.displayStatusValue(rawMcpStatusLabel);
    final acpStatusLabel = _acpStatusLabel(target, strings);

    return Container(
      key: Key('mcp-plugin-config-card-${target.target}'),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.line.withAlpha(90)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 10, 0),
            child: Row(
              children: [
                AgentBrandIcon(
                  target: target,
                  detected: target.status != 'not-detected',
                  selected: target.configured,
                  size: 34,
                  iconSize: 22,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        target.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.text,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        strings.configureMcpPlugins,
                        style: TextStyle(
                          color: colors.textMuted,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: Icon(Icons.close_rounded, color: colors.textMuted),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
            child: _PluginIdentity(
              target: target,
              configPath: configPath,
              busy: busy,
              onOpenPath: (path) => controller.openDirectoryPath(
                _directoryForMcpPath(path),
                caption: strings.mcpConfig,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _PluginLaneCell(
                    title: strings.mcpPluginColumn,
                    supported: target.supportsMcpPluginInstall,
                    statusLabel: mcpStatusLabel,
                    statusTone: _statusTone(target, rawMcpStatusLabel),
                    busy: busy,
                    action: _mcpActionButton(
                      context,
                      kind: mcpAction,
                      busy: busy,
                      onPressed: mcpAction == null
                          ? null
                          : () {
                              if (mcpAction == _McpActionKind.reinstall) {
                                controller.reinstallMcpPlugin(target);
                              } else {
                                controller.updateMcpPlugin(target);
                              }
                            },
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _PluginLaneCell(
                    title: strings.acpPluginColumn,
                    supported: target.supportsAcpPlugin,
                    statusLabel: acpStatusLabel,
                    statusTone: _acpStatusTone(target),
                    busy: false,
                    action: null,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PluginIdentity extends StatelessWidget {
  const _PluginIdentity({
    required this.target,
    required this.configPath,
    required this.busy,
    required this.onOpenPath,
  });

  final TargetCandidate target;
  final String configPath;
  final bool busy;
  final Future<void> Function(String path) onOpenPath;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final pathValue = _identityPathFor(target, configPath);
    final pathCanOpen = _identityPathCanOpen(target);
    if (pathValue == null) {
      return Text(
        configPath,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: colors.textMuted,
          fontSize: 11.5,
          fontWeight: FontWeight.w500,
        ),
      );
    }
    return DirectoryPathField(
      title: pathCanOpen ? strings.configPath : strings.binaryPath,
      label: pathCanOpen ? strings.configPath : strings.binaryPath,
      path: pathValue,
      readOnly: true,
      showHeader: false,
      compactBreakpoint: 420,
      enabled: !busy,
      openEnabled: pathCanOpen,
      valueTextStyle: const TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w600,
      ),
      padding: EdgeInsets.zero,
      onOpen: onOpenPath,
    );
  }
}

enum _McpActionKind { install, update, reinstall }

_McpActionKind? _mcpActionKindFor(TargetCandidate target) {
  if (!target.supportsMcpPluginInstall) {
    return null;
  }
  if (_isPartialCapability(target)) {
    return _McpActionKind.reinstall;
  }
  if (!target.canUpdateMcpPlugin) {
    return null;
  }
  if (!target.configured) {
    return _McpActionKind.install;
  }
  return _McpActionKind.update;
}

enum _PluginStatusTone { ok, warning, error }

class _PluginLaneCell extends StatelessWidget {
  const _PluginLaneCell({
    required this.title,
    required this.supported,
    required this.statusLabel,
    required this.statusTone,
    required this.busy,
    required this.action,
  });

  final String title;
  final bool supported;
  final String statusLabel;
  final _PluginStatusTone statusTone;
  final bool busy;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      decoration: BoxDecoration(
        color: colors.surfaceLow.withAlpha(120),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.line.withAlpha(60)),
      ),
      child: !supported
          ? Opacity(
              opacity: 0.55,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: colors.text,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Icon(Icons.block, size: 16, color: colors.textMuted),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          strings.pluginUnsupported,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.textMuted,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: colors.text,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    _PluginStatusIcon(label: statusLabel, tone: statusTone),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        statusLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.textMuted,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                if (action != null) ...[
                  const SizedBox(height: 10),
                  action!,
                ] else if (busy)
                  const Padding(
                    padding: EdgeInsets.only(top: 10),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
              ],
            ),
    );
  }
}

Widget? _mcpActionButton(
  BuildContext context, {
  required _McpActionKind? kind,
  required bool busy,
  required VoidCallback? onPressed,
}) {
  if (kind == null || onPressed == null) {
    return null;
  }
  final strings = LicoStrings.of(context);
  return switch (kind) {
    _McpActionKind.reinstall => AppleGlassActionButton(
      label: strings.reinstall,
      icon: Icons.refresh_rounded,
      onPressed: busy ? null : onPressed,
      emphasized: true,
    ),
    _McpActionKind.update => AppleGlassActionButton(
      label: strings.update,
      icon: Icons.system_update_alt_outlined,
      onPressed: busy ? null : onPressed,
      emphasized: true,
    ),
    _McpActionKind.install => AppleGlassActionButton(
      label: strings.install,
      icon: Icons.download_rounded,
      onPressed: busy ? null : onPressed,
      emphasized: true,
    ),
  };
}

class _PluginStatusIcon extends StatelessWidget {
  const _PluginStatusIcon({required this.label, required this.tone});

  final String label;
  final _PluginStatusTone tone;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final (icon, color) = switch (tone) {
      _PluginStatusTone.ok => (
        Icons.check_circle_outline_rounded,
        Colors.green.shade500,
      ),
      _PluginStatusTone.warning => (
        Icons.priority_high_rounded,
        colors.warning,
      ),
      _PluginStatusTone.error => (Icons.error_outline_rounded, colors.error),
    };
    return Tooltip(
      message: label,
      child: Icon(
        icon,
        key: Key('plugin-status-icon-${label.toLowerCase()}'),
        size: 16,
        color: color,
      ),
    );
  }
}

String _configPathFor(TargetCandidate target) {
  final configPath = target.configPath?.trim();
  if (configPath != null && configPath.isNotEmpty) {
    return configPath;
  }
  final detail = target.detail?.trim();
  if (detail != null && detail.isNotEmpty) {
    return detail;
  }
  final binaryPath = target.binaryPath?.trim();
  if (binaryPath != null && binaryPath.isNotEmpty) {
    return binaryPath;
  }
  return target.kind;
}

String _statusLabelFor(TargetCandidate target, Map<String, dynamic>? status) {
  final value =
      status?['status'] ??
      status?['state'] ??
      (target.configured ? 'configured' : target.status);
  final label = value.toString().trim();
  if (label.isEmpty) {
    return 'unknown';
  }
  return label;
}

String _acpStatusLabel(TargetCandidate target, LicoStrings strings) {
  if (!target.supportsAcpPlugin) {
    return strings.pluginUnsupported;
  }
  final readiness = target.conversationReadiness.trim();
  if (readiness.isEmpty) {
    return strings.acpDeclared;
  }
  return strings.displayStatusValue(readiness);
}

_PluginStatusTone _acpStatusTone(TargetCandidate target) {
  if (!target.supportsAcpPlugin) {
    return _PluginStatusTone.error;
  }
  final readiness = target.conversationReadiness.trim().toLowerCase();
  if (readiness.isEmpty || readiness == 'ready' || readiness == 'verified') {
    return _PluginStatusTone.ok;
  }
  if (readiness == 'blocked' ||
      readiness == 'unavailable' ||
      readiness == 'history-only' ||
      readiness.contains('error') ||
      readiness.contains('fail')) {
    return _PluginStatusTone.error;
  }
  return _PluginStatusTone.warning;
}

bool _isPartialCapability(TargetCandidate target) {
  return target.adapterStatus == 'partial';
}

_PluginStatusTone _statusTone(TargetCandidate target, String statusLabel) {
  final lower = statusLabel.toLowerCase().replaceAll('-', '_');
  if (target.adapterStatus == 'unsupported' ||
      lower.contains('error') ||
      lower.contains('fail') ||
      lower.contains('unsupported') ||
      lower == 'not_detected' ||
      lower == 'not configured' ||
      lower == 'not_configured') {
    return _PluginStatusTone.error;
  }
  if (lower == 'unverified' ||
      lower == 'partial' ||
      lower == 'pending' ||
      lower == 'waiting') {
    return _PluginStatusTone.warning;
  }
  return _PluginStatusTone.ok;
}

bool _isMcpPluginTarget(TargetCandidate target) {
  return target.visibleInClient &&
      target.target != 'code' &&
      target.target != 'vscode';
}

bool _looksLikeFileSystemPath(String value) {
  final trimmed = value.trim();
  return trimmed.startsWith('/') ||
      trimmed.startsWith('~/') ||
      RegExp(r'^[A-Za-z]:[\\/]').hasMatch(trimmed);
}

String? _identityPathFor(TargetCandidate target, String fallback) {
  final configPath = target.configPath?.trim();
  if (configPath != null &&
      configPath.isNotEmpty &&
      _looksLikeFileSystemPath(configPath)) {
    return configPath;
  }
  final binaryFromFallback = _extractBinaryPath(fallback);
  if (binaryFromFallback != null) {
    return binaryFromFallback;
  }
  final binaryPath = target.binaryPath?.trim();
  if (binaryPath != null &&
      binaryPath.isNotEmpty &&
      _looksLikeFileSystemPath(binaryPath)) {
    return binaryPath;
  }
  final trimmedFallback = fallback.trim();
  return _looksLikeFileSystemPath(trimmedFallback) ? trimmedFallback : null;
}

bool _identityPathCanOpen(TargetCandidate target) {
  final configPath = target.configPath?.trim();
  return configPath != null &&
      configPath.isNotEmpty &&
      _looksLikeFileSystemPath(configPath);
}

String? _extractBinaryPath(String value) {
  final match = RegExp(
    r'^\s*binary\s*:\s*(.+?)\s*$',
    caseSensitive: false,
  ).firstMatch(value);
  final binaryPath = match?.group(1)?.trim();
  if (binaryPath == null || binaryPath.isEmpty) {
    return null;
  }
  return _looksLikeFileSystemPath(binaryPath) ? binaryPath : null;
}

String _directoryForMcpPath(String path) {
  final trimmed = path.trim();
  if (trimmed.isEmpty) {
    return trimmed;
  }
  return p.dirname(trimmed);
}
