import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/contracts/local_runtime_preferences.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/shared/ui/directory_path_field.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

/// Compact runtime configuration card shown inside Settings.
///
/// Mirrors the essential controls from [LocalRuntimePanel] but lives as a
/// single card in the settings list. A "Details" button still allows opening
/// the full runtime panel for module browsing and logs.
class LocalRuntimeSettingsCard extends StatefulWidget {
  const LocalRuntimeSettingsCard({
    super.key,
    required this.controller,
    this.onOpenDetails,
  });

  final ClientController controller;
  final VoidCallback? onOpenDetails;

  @override
  State<LocalRuntimeSettingsCard> createState() =>
      _LocalRuntimeSettingsCardState();
}

class _LocalRuntimeSettingsCardState extends State<LocalRuntimeSettingsCard> {
  late final TextEditingController _sourceRootController;
  late final TextEditingController _presetConfigController;
  late final TextEditingController _portController;

  ClientController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    final preferences = controller.localRuntimePreferences;
    _sourceRootController = TextEditingController(text: preferences.sourceRoot);
    _presetConfigController = TextEditingController(
      text: preferences.presetConfig,
    );
    _portController = TextEditingController(text: preferences.port.toString());
  }

  @override
  void didUpdateWidget(covariant LocalRuntimeSettingsCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final preferences = controller.localRuntimePreferences;
    _syncController(_sourceRootController, preferences.sourceRoot);
    _syncController(_presetConfigController, preferences.presetConfig);
    _syncController(_portController, preferences.port.toString());
  }

  @override
  void dispose() {
    _sourceRootController.dispose();
    _presetConfigController.dispose();
    _portController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final state = controller.localRuntimeState ?? const <String, dynamic>{};
    final running = state['running'] == true || state['status'] == 'running';
    final canEnable =
        _sourceRootController.text.trim().isNotEmpty &&
        _presetConfigController.text.trim().isNotEmpty &&
        !controller.isLocalRuntimeBusy;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(Icons.dns_outlined, color: colors.primary, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      strings.runtime,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: colors.text,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      strings.runtimeConfig,
                      style: TextStyle(fontSize: 11, color: colors.textMuted),
                    ),
                  ],
                ),
              ),
              _StatusPill(running: running),
              const SizedBox(width: 10),
              FilledButton.icon(
                onPressed: canEnable
                    ? () => unawaited(_enableRuntime(rebuild: false))
                    : null,
                icon: Icon(
                  running
                      ? Icons.check_circle_outline
                      : Icons.play_arrow_rounded,
                  size: 15,
                ),
                label: Text(running ? strings.running : strings.enable),
              ),
            ],
          ),
          const SizedBox(height: 14),
          DirectoryPathField(
            title: strings.sourceRepository,
            label: strings.sourceRepository,
            controller: _sourceRootController,
            icon: Icons.folder_open_outlined,
            enabled: !controller.isLocalRuntimeBusy,
            padding: EdgeInsets.zero,
            onOpen: (path) => controller.openDirectoryPath(
              path,
              caption: strings.sourceRepository,
            ),
          ),
          const SizedBox(height: 10),
          DirectoryPathField(
            title: strings.presetConfig,
            label: strings.presetConfig,
            controller: _presetConfigController,
            icon: Icons.rule_folder_outlined,
            enabled: !controller.isLocalRuntimeBusy,
            padding: EdgeInsets.zero,
            onOpen: (path) => controller.openDirectoryPath(
              _directoryForPath(path),
              caption: strings.presetConfig,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 140,
                child: TextField(
                  controller: _portController,
                  enabled: !controller.isLocalRuntimeBusy,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: strings.port,
                    prefixIcon: Icon(
                      Icons.tag_outlined,
                      size: 16,
                      color: colors.textMuted,
                    ),
                  ),
                ),
              ),
              const Spacer(),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.start,
            children: [
              OutlinedButton.icon(
                onPressed: canEnable
                    ? () => unawaited(_enableRuntime(rebuild: true))
                    : null,
                icon: const Icon(Icons.construction_outlined, size: 15),
                label: Text(strings.rebuild),
              ),
              OutlinedButton.icon(
                onPressed: controller.isLocalRuntimeBusy || !running
                    ? null
                    : () =>
                          unawaited(controller.restartConfiguredLocalRuntime()),
                icon: const Icon(Icons.restart_alt_outlined, size: 15),
                label: Text(strings.restart),
              ),
              if (running)
                TextButton.icon(
                  onPressed: controller.isLocalRuntimeBusy
                      ? null
                      : () => unawaited(controller.stopLocalRuntime()),
                  icon: const Icon(Icons.stop_circle_outlined, size: 15),
                  label: Text(strings.stop),
                  style: TextButton.styleFrom(foregroundColor: colors.error),
                ),
              TextButton.icon(
                onPressed: controller.isLocalRuntimeBusy
                    ? null
                    : () => unawaited(controller.loadLocalRuntimeLogs()),
                icon: const Icon(Icons.receipt_long_outlined, size: 15),
                label: Text(strings.logs),
              ),
              if (widget.onOpenDetails != null)
                TextButton.icon(
                  onPressed: widget.onOpenDetails,
                  icon: const Icon(Icons.open_in_new_outlined, size: 15),
                  label: Text(strings.moreActions),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _enableRuntime({required bool rebuild}) {
    return controller.ensureLocalRuntime(
      sourceRoot: _sourceRootController.text,
      presetConfig: _presetConfigController.text,
      port: _port(),
      rebuild: rebuild,
    );
  }

  int _port() {
    final parsed = int.tryParse(_portController.text.trim());
    if (parsed == null || parsed <= 0 || parsed > 65535) {
      return LocalRuntimePreferences.defaultPort;
    }
    return parsed;
  }

  void _syncController(TextEditingController controller, String value) {
    if (controller.text == value) {
      return;
    }
    controller.text = value;
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.running});

  final bool running;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final color = running ? colors.success : colors.textMuted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            running ? Icons.circle : Icons.circle_outlined,
            size: 8,
            color: color,
          ),
          const SizedBox(width: 6),
          Text(
            running ? strings.running : strings.stopped,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

String _directoryForPath(String path) {
  final trimmed = path.trim();
  if (trimmed.isEmpty || trimmed == '-') {
    return '';
  }
  final basename = p.basename(trimmed);
  return basename.contains('.') ? p.dirname(trimmed) : trimmed;
}
