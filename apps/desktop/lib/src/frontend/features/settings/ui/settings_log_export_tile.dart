import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/shared/ui/directory_path_field.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

class SettingsLogExportTile extends StatelessWidget {
  const SettingsLogExportTile({super.key, required this.controller});

  final ClientController controller;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final exportedPath = controller.clientLogExportPath.trim();
    final exportButton = FilledButton.tonalIcon(
      onPressed: controller.isExportingClientLogs
          ? null
          : () => unawaited(_chooseAndExport(context)),
      icon: controller.isExportingClientLogs
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.file_download_outlined),
      label: Text(strings.exportLogs),
    );
    if (exportedPath.isNotEmpty) {
      return DirectoryPathField(
        title: strings.clientLogs,
        label: strings.clientLogs,
        path: exportedPath,
        icon: Icons.file_download_outlined,
        readOnly: true,
        actions: [exportButton],
        onOpen: (path) => controller.openDirectoryPath(
          p.dirname(path),
          caption: strings.clientLogs,
        ),
      );
    }
    final subtitle = strings.exportLogsDescription.trim();
    return ListTile(
      leading: Icon(Icons.file_download_outlined, color: colors.primary),
      title: Text(strings.clientLogs),
      subtitle: subtitle.isEmpty ? null : Text(subtitle),
      trailing: exportButton,
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
    await controller.exportClientLogs(location.path);
  }
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
  return 'lico-arc-client-logs-$stamp.jsonl';
}
