import 'dart:async';

import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/plugin_window_host_models.dart';
import 'package:licoup/src/frontend/binding/projection_builder.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_glass_option_card.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_hover_popover.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';
import 'package:licoup/src/frontend/shared/ui/lico_icon_button.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/theme_colors.dart';
import 'package:licoup/src/presentation/plugin_window/plugin_window_binding.dart';
import 'package:licoup/src/presentation/plugin_window/plugin_window_intent.dart';
import 'package:licoup/src/presentation/plugin_window/plugin_window_projection.dart';

enum _WindowMenuAction { permissionSettings, close }

/// Title-row actions of one plugin window: the sandbox chip listing the
/// declared permissions, reload, and the window menu.
final class PluginWindowTitleActions extends StatelessWidget {
  const PluginWindowTitleActions({
    super.key,
    required this.binding,
    required this.pluginId,
    required this.onOpenPermissionSettings,
    required this.onClose,
  });

  final PluginWindowBinding binding;
  final String pluginId;
  final VoidCallback onOpenPermissionSettings;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    return ProjectionBuilder<PluginWindowProjection, PluginWindowManifest?>(
      source: binding.projection,
      select: (projection) => projection.manifest(pluginId),
      builder: (context, manifest) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (manifest != null) ...[
            PluginWindowSandboxChip(manifest: manifest),
            const SizedBox(width: 6),
          ],
          LicoIconButton(
            key: const Key('plugin-window-reload'),
            icon: const Icon(Icons.refresh_rounded),
            tooltip: strings.pluginWindowReload,
            onPressed: () => binding.intents.send(ReloadPluginWindow(pluginId)),
          ),
          Builder(
            builder: (buttonContext) => LicoIconButton(
              key: const Key('plugin-window-menu'),
              icon: const Icon(Icons.more_horiz_rounded),
              tooltip: strings.pluginWindowMore,
              onPressed: () => unawaited(_openMenu(buttonContext, strings)),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openMenu(BuildContext context, LicoStrings strings) async {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final action = await showMessagingGlassMenu<_WindowMenuAction>(
      context: context,
      menuKey: const Key('plugin-window-menu-card'),
      globalPosition: box.localToGlobal(Offset(0, box.size.height + 4)),
      actions: [
        MessagingGlassMenuAction(
          value: _WindowMenuAction.permissionSettings,
          label: strings.pluginWindowPermissionSettings,
          leading: const Icon(Icons.admin_panel_settings_outlined, size: 16),
        ),
        MessagingGlassMenuAction(
          value: _WindowMenuAction.close,
          label: strings.pluginWindowClose,
          leading: const Icon(Icons.close_rounded, size: 16),
        ),
      ],
    );
    switch (action) {
      case _WindowMenuAction.permissionSettings:
        onOpenPermissionSettings();
      case _WindowMenuAction.close:
        onClose();
      case null:
        break;
    }
  }
}

/// The "Sandbox" chip; hovering or clicking opens the declared permissions.
final class PluginWindowSandboxChip extends StatelessWidget {
  const PluginWindowSandboxChip({super.key, required this.manifest});

  final PluginWindowManifest manifest;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    return MessagingHoverPopover(
      popoverKey: const Key('plugin-window-sandbox-popover'),
      width: 300,
      targetAnchor: Alignment.bottomLeft,
      followerAnchor: Alignment.topLeft,
      offset: const Offset(0, 6),
      triggerBuilder:
          (context, {required open, required toggle, required close}) =>
              _SandboxChipFace(
                label: strings.pluginWindowSandbox,
                open: open,
                onTap: toggle,
              ),
      cardBuilder: (context, close) => _SandboxPermissions(manifest: manifest),
    );
  }
}

final class _SandboxChipFace extends StatelessWidget {
  const _SandboxChipFace({
    required this.label,
    required this.open,
    required this.onTap,
  });

  final String label;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final radius = BorderRadius.circular(999);
    return Semantics(
      button: true,
      expanded: open,
      label: label,
      child: ExcludeSemantics(
        child: InkWell(
          key: const Key('plugin-window-sandbox-chip'),
          onTap: onTap,
          borderRadius: radius,
          child: AnimatedContainer(
            duration: context.motion(LicoMotion.micro),
            curve: LicoMotion.standard,
            padding: const EdgeInsets.fromLTRB(8, 3, 10, 3),
            decoration: continuousHairlineDecoration(
              color: open ? colors.accentGlow : colors.accentSurface,
              borderRadius: radius,
              stroke: colors.accentBorder,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.shield_outlined,
                  size: 13,
                  color: colors.accentStrong,
                ),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: colors.accentStrong,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _SandboxPermissions extends StatelessWidget {
  const _SandboxPermissions({required this.manifest});

  final PluginWindowManifest manifest;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final textTheme = Theme.of(context).textTheme;
    final permissions = manifest.permissions;
    final rows = <(String, String)>[
      (
        strings.pluginWindowNetwork,
        permissions.network.isEmpty
            ? strings.pluginWindowNone
            : strings.pluginWindowNetworkAllowed(permissions.network),
      ),
      // The manifest has no file permission: plugins read only their bundle
      // and their own storage partition.
      (strings.pluginWindowLocalFiles, strings.pluginWindowNone),
      (
        strings.pluginWindowClipboard,
        strings.pluginWindowClipboardAccess(permissions.clipboard),
      ),
      (
        strings.pluginWindowCapabilities,
        permissions.capabilities.isEmpty
            ? strings.pluginWindowNone
            : permissions.capabilities.join(', '),
      ),
    ];
    return Padding(
      key: const Key('plugin-window-sandbox-permissions'),
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.shield_outlined, size: 14, color: colors.textMuted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  strings.pluginWindowSandboxTitle(manifest.name),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: colors.text,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final (label, value) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 92,
                    child: Text(
                      label,
                      style: textTheme.bodySmall?.copyWith(
                        color: colors.textMuted,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      value,
                      textAlign: TextAlign.end,
                      style: textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: colors.text,
                      ),
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
