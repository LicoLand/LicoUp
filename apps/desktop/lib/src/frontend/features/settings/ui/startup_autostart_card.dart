import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/binding/projection_builder.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/settings/settings_binding.dart';
import 'package:licoup/src/presentation/settings/settings_intent.dart';
import 'package:licoup/src/presentation/settings/settings_projection.dart';

/// Settings card: login autostart for the desktop client and background helpers.
final class StartupAutostartCard extends StatefulWidget {
  const StartupAutostartCard({super.key, required this.binding});

  final SettingsBinding binding;

  @override
  State<StartupAutostartCard> createState() => _StartupAutostartCardState();
}

final class _StartupAutostartCardState extends State<StartupAutostartCard> {
  @override
  void initState() {
    super.initState();
    widget.binding.intents.send(const RefreshSettingsAutostart());
  }

  @override
  void didUpdateWidget(StartupAutostartCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.binding, widget.binding)) {
      widget.binding.intents.send(const RefreshSettingsAutostart());
    }
  }

  @override
  Widget build(BuildContext context) {
    return ProjectionBuilder<
      SettingsAutostartProjection,
      SettingsAutostartProjection
    >(
      source: widget.binding.autostart,
      select: _autostartIdentity,
      builder: _buildProjection,
    );
  }

  Widget _buildProjection(
    BuildContext context,
    SettingsAutostartProjection projection,
  ) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final presentation = layoutSettingsPresentationOf(context);
    final loading = projection.phase == SettingsAutostartPhase.loading;
    final busy = projection.phase == SettingsAutostartPhase.applying;
    final enabled = projection.supported && !loading && !busy;
    final (message, messageIsError) = switch (projection.result) {
      SettingsAutostartResult.saved => (strings.startupAutostartSaved, false),
      SettingsAutostartResult.loadFailed => (
        strings.startupAutostartLoadFailed,
        true,
      ),
      SettingsAutostartResult.saveFailed => (
        projection.supported
            ? strings.startupAutostartSaveFailed
            : strings.startupAutostartUnsupported,
        true,
      ),
      SettingsAutostartResult.none => (null, false),
    };
    return Padding(
      key: const Key('startup-autostart-card'),
      padding: presentation.rowPadding,
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
              if (loading || busy)
                const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          if (message != null) ...[
            const SizedBox(height: 10),
            Text(
              message,
              style: TextStyle(
                color: messageIsError ? colors.error : colors.textMuted,
                fontSize: 12,
              ),
            ),
          ] else if (!loading && !projection.supported) ...[
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
            value: projection.desktopEnabled,
            onChanged: !enabled
                ? null
                : (value) => widget.binding.intents.send(
                    SetSettingsAutostart(
                      component: SettingsAutostartComponent.desktop,
                      enabled: value,
                      silent: projection.desktopSilent,
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
              value: projection.desktopSilent,
              onChanged: !enabled || !projection.desktopEnabled
                  ? null
                  : (value) => widget.binding.intents.send(
                      SetSettingsAutostart(
                        component: SettingsAutostartComponent.desktop,
                        enabled: true,
                        silent: value,
                      ),
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
            value: projection.gatewayEnabled,
            onChanged: !enabled
                ? null
                : (value) => widget.binding.intents.send(
                    SetSettingsAutostart(
                      component: SettingsAutostartComponent.gateway,
                      enabled: value,
                    ),
                  ),
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
            value: projection.mcpEnabled,
            onChanged: !enabled
                ? null
                : (value) => widget.binding.intents.send(
                    SetSettingsAutostart(
                      component: SettingsAutostartComponent.mcp,
                      enabled: value,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

SettingsAutostartProjection _autostartIdentity(
  SettingsAutostartProjection value,
) => value;

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
