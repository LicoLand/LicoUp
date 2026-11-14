import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_flutter/presentation_flutter.dart';

import 'package:licoup/src/frontend/features/settings/ui/settings_control_metrics.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/shared/ui/base_surface.dart';
import 'package:licoup/src/frontend/shared/ui/directory_path_field.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/lico_elevation.dart';
import 'package:licoup/src/frontend/shared/ui/lico_loading_indicator.dart';
import 'package:licoup/src/frontend/shared/ui/lico_section_header.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/settings/settings_binding.dart';
import 'package:licoup/src/presentation/settings/settings_inputs.dart';
import 'package:licoup/src/presentation/settings/settings_intent.dart';
import 'package:licoup/src/presentation/settings/settings_providers.dart';

/// Diagnostics section: the client log export is the primary diagnostics
/// action, so it gets a real card — title, description, and a prominent
/// action — instead of a bare tile between section hairlines.
class DiagnosticsSettingsSection extends StatelessWidget {
  const DiagnosticsSettingsSection({super.key, required this.binding});

  final SettingsBinding binding;

  @override
  Widget build(BuildContext context) =>
      AsyncRegion<SettingsLogExportInputs, IntentSink<SettingsIntent>>(
        source: settingsLogExportInputsProvider,
        actions: binding.intents,
        loading: (_, _) => const SizedBox.shrink(),
        data: (context, inputs, _) =>
            _buildSection(context, inputs.path, inputs.busy),
      );

  Widget _buildSection(BuildContext context, String exportPath, bool busy) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final presentation = layoutSettingsPresentationOf(context);
    final exportedPath = exportPath.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LicoSectionHeader(
          key: const Key('settings-section-header-diagnostics'),
          title: strings.diagnostics,
          leading: Icon(
            Icons.bug_report_outlined,
            size: 18,
            color: colors.textSecondary,
          ),
          padding: presentation.sectionHeaderPadding,
        ),
        Padding(
          padding: presentation.rowPadding,
          child: _DiagnosticsSurface(
            key: const Key('settings-log-export-card'),
            elevation: LicoElevation.flat,
            padding: const EdgeInsets.all(LicoContentSpacing.item),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LayoutBuilder(
                  builder: (context, constraints) {
                    final compact = constraints.maxWidth < 560;
                    final summary = Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.file_download_outlined,
                          size: 18,
                          color: colors.textSecondary,
                        ),
                        const SizedBox(width: LicoContentSpacing.compact),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                strings.clientLogs,
                                style: Theme.of(context).textTheme.titleSmall
                                    ?.copyWith(
                                      color: colors.text,
                                      fontWeight: FontWeight.w600,
                                    ),
                              ),
                              const SizedBox(
                                height: LicoContentSpacing.inline / 2,
                              ),
                              Text(
                                strings.exportLogsDescription.trim(),
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(color: colors.textMuted),
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                    final exportButton = SizedBox(
                      height: settingsControlHeight,
                      child: FilledButton.icon(
                        key: const Key('settings-export-logs-button'),
                        onPressed: busy
                            ? null
                            : () => unawaited(_chooseAndExport(context)),
                        icon: busy
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: LicoLoadingIndicator(strokeWidth: 2),
                              )
                            : const Icon(
                                Icons.file_download_outlined,
                                size: 16,
                              ),
                        label: Text(strings.exportLogs),
                      ),
                    );
                    if (compact) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          summary,
                          const SizedBox(height: LicoContentSpacing.item),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: exportButton,
                          ),
                        ],
                      );
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(child: summary),
                        const SizedBox(width: LicoContentSpacing.item),
                        exportButton,
                      ],
                    );
                  },
                ),
                if (exportedPath.isNotEmpty) ...[
                  const SizedBox(height: LicoContentSpacing.item),
                  DirectoryPathField(
                    title: strings.clientLogs,
                    label: strings.clientLogs,
                    path: exportedPath,
                    icon: Icons.file_download_outlined,
                    readOnly: true,
                    showHeader: false,
                    padding: EdgeInsets.zero,
                    onOpen: (_) {
                      binding.intents.send(
                        OpenSettingsDirectory(
                          SettingsDirectory.clientLogs,
                          caption: strings.clientLogs,
                        ),
                      );
                      return Future<void>.value();
                    },
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _chooseAndExport(BuildContext context) async {
    final strings = LicoStrings.of(context);
    final location = await getSaveLocation(
      suggestedName: _clientLogFileName(),
      confirmButtonText: strings.exportLogs,
      canCreateDirectories: true,
      acceptedTypeGroups: _clientLogTypeGroups(strings),
    );
    if (location == null) {
      return;
    }
    binding.intents.send(ExportClientDiagnostics(location.path));
  }
}

final class _DiagnosticsSurface extends BaseSurface {
  const _DiagnosticsSurface({
    super.key,
    required super.child,
    super.elevation,
    super.padding,
  });
}

// Keep file-format names stable while localizing the human-readable chooser
// label. `XTypeGroup` is immutable, so it is built outside the const list.
List<XTypeGroup> _clientLogTypeGroups(LicoStrings strings) => [
  const XTypeGroup(label: 'JSONL', extensions: ['jsonl']),
  XTypeGroup(label: strings.plainTextFile, extensions: const ['txt']),
];

String _clientLogFileName() {
  final now = DateTime.now().toLocal();
  String twoDigits(int value) => value.toString().padLeft(2, '0');
  final stamp =
      '${now.year}'
      '${twoDigits(now.month)}'
      '${twoDigits(now.day)}-'
      '${twoDigits(now.hour)}'
      '${twoDigits(now.minute)}'
      '${twoDigits(now.second)}';
  return 'lico-up-client-logs-$stamp.jsonl';
}
