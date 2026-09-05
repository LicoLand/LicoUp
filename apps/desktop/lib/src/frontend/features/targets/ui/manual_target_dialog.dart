import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/directory_path_field.dart';
import 'package:licoup/src/presentation/targets/targets_projection.dart';

class ManualTargetDraft {
  const ManualTargetDraft({
    required this.target,
    required this.configPath,
    required this.binaryPath,
    required this.historyRoot,
    this.location = 'local',
    this.runtimeConnection = const <String, dynamic>{},
  });

  final String target;
  final String configPath;
  final String binaryPath;
  final String historyRoot;
  final String location;
  final Map<String, dynamic> runtimeConnection;
}

class ManualTargetDialog extends StatefulWidget {
  const ManualTargetDialog({
    super.key,
    required this.options,
    this.onOpenDirectory,
  });

  final List<ManualTargetOptionProjection> options;
  final FutureOr<void> Function(String path)? onOpenDirectory;

  @override
  State<ManualTargetDialog> createState() => _ManualTargetDialogState();
}

class _ManualTargetDialogState extends State<ManualTargetDialog> {
  final _configPathController = TextEditingController();
  final _binaryPathController = TextEditingController();
  final _historyRootController = TextEditingController();
  final _hostController = TextEditingController();
  final _portController = TextEditingController();
  final _userController = TextEditingController();
  final _remoteExecutableController = TextEditingController();
  final _remoteWorkingDirectoryController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  late String _target;
  String _location = 'local';

  bool get _supportsVirtualMachine => widget.options.any(
    (option) => option.id == _target && option.supportsVirtualMachine,
  );
  bool get _usesVirtualMachine =>
      _supportsVirtualMachine && _location == 'virtual-machine';

  @override
  void initState() {
    super.initState();
    assert(widget.options.isNotEmpty);
    _target = widget.options.first.id;
  }

  @override
  void dispose() {
    _configPathController.dispose();
    _binaryPathController.dispose();
    _historyRootController.dispose();
    _hostController.dispose();
    _portController.dispose();
    _userController.dispose();
    _remoteExecutableController.dispose();
    _remoteWorkingDirectoryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    return AlertDialog(
      title: Text(strings.addTarget),
      key: const Key('manual-target-dialog'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  key: const Key('manual-target-kind'),
                  initialValue: _target,
                  decoration: InputDecoration(labelText: strings.target),
                  items: [
                    for (final option in widget.options)
                      DropdownMenuItem(
                        value: option.id,
                        child: Text(option.label),
                      ),
                  ],
                  onChanged: (value) {
                    if (value == null) {
                      return;
                    }
                    setState(() {
                      final previousTarget = _target;
                      _target = value;
                      if (!_supportsVirtualMachine) {
                        _location = 'local';
                      } else if (_remoteExecutableController.text.isEmpty ||
                          _remoteExecutableController.text == previousTarget) {
                        _remoteExecutableController.text = _target;
                      }
                    });
                  },
                ),
                const SizedBox(height: 12),
                KeyedSubtree(
                  key: const Key('manual-target-location'),
                  child: DropdownButtonFormField<String>(
                    key: ValueKey('manual-target-location-$_target'),
                    initialValue: _location,
                    decoration: InputDecoration(
                      labelText: strings.targetLocation,
                    ),
                    items: [
                      DropdownMenuItem(
                        value: 'local',
                        child: Text(strings.localMachine),
                      ),
                      if (_supportsVirtualMachine)
                        DropdownMenuItem(
                          value: 'virtual-machine',
                          child: Text(strings.virtualMachine),
                        ),
                    ],
                    onChanged: (value) {
                      if (value == null) {
                        return;
                      }
                      setState(() {
                        _location = value;
                        if (_usesVirtualMachine &&
                            _remoteExecutableController.text.trim().isEmpty) {
                          _remoteExecutableController.text = _target;
                        }
                      });
                    },
                  ),
                ),
                if (_usesVirtualMachine) ...[
                  const SizedBox(height: 12),
                  TextFormField(
                    key: const Key('manual-target-vm-host'),
                    controller: _hostController,
                    decoration: InputDecoration(
                      labelText: strings.virtualMachineHost,
                    ),
                    validator: (value) => _requiredSshValue(value, strings),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    key: const Key('manual-target-vm-port'),
                    controller: _portController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(labelText: strings.sshPort),
                    validator: (value) {
                      final normalized = value?.trim() ?? '';
                      if (normalized.isEmpty) return null;
                      final port = int.tryParse(normalized);
                      return port != null && port > 0 && port <= 65535
                          ? null
                          : strings.invalidSshValue;
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    key: const Key('manual-target-vm-user'),
                    controller: _userController,
                    decoration: InputDecoration(labelText: strings.sshUser),
                    validator: (value) {
                      final normalized = value?.trim() ?? '';
                      if (normalized.isEmpty) return null;
                      return _isSafeSshUser(normalized)
                          ? null
                          : strings.invalidSshValue;
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    key: const Key('manual-target-vm-executable'),
                    controller: _remoteExecutableController,
                    decoration: InputDecoration(
                      labelText: strings.remoteExecutable,
                    ),
                    validator: (value) => _requiredRemoteValue(value, strings),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    key: const Key('manual-target-vm-working-directory'),
                    controller: _remoteWorkingDirectoryController,
                    decoration: InputDecoration(
                      labelText: strings.remoteWorkingDirectory,
                    ),
                    validator: (value) {
                      final normalized = value?.trim() ?? '';
                      return normalized.startsWith('/') &&
                              normalized.length <= 4096 &&
                              !normalized.contains(RegExp(r'[\r\n\u0000]'))
                          ? null
                          : strings.absoluteGuestPathRequired;
                    },
                  ),
                ] else ...[
                  const SizedBox(height: 12),
                  DirectoryPathField(
                    title: strings.configPath,
                    label: strings.configPath,
                    controller: _configPathController,
                    showHeader: false,
                    compactBreakpoint: 360,
                    padding: EdgeInsets.zero,
                    onOpen: (path) => _openDirectory(p.dirname(path)),
                  ),
                  const SizedBox(height: 12),
                  DirectoryPathField(
                    title: strings.binaryPath,
                    label: strings.binaryPath,
                    controller: _binaryPathController,
                    showHeader: false,
                    compactBreakpoint: 360,
                    padding: EdgeInsets.zero,
                    onOpen: (path) => _openDirectory(p.dirname(path)),
                  ),
                  const SizedBox(height: 12),
                  DirectoryPathField(
                    title: strings.historyRoot,
                    label: strings.historyRoot,
                    controller: _historyRootController,
                    showHeader: false,
                    compactBreakpoint: 360,
                    padding: EdgeInsets.zero,
                    onOpen: _openDirectory,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('manual-target-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.cancel),
        ),
        FilledButton(
          key: const Key('manual-target-submit'),
          onPressed: _submit,
          child: Text(strings.addTarget),
        ),
      ],
    );
  }

  void _submit() {
    if (_usesVirtualMachine && _formKey.currentState?.validate() != true) {
      return;
    }
    final port = int.tryParse(_portController.text.trim());
    final user = _userController.text.trim();
    Navigator.of(context).pop(
      ManualTargetDraft(
        target: _target,
        configPath: _usesVirtualMachine
            ? ''
            : _configPathController.text.trim(),
        binaryPath: _usesVirtualMachine
            ? ''
            : _binaryPathController.text.trim(),
        historyRoot: _usesVirtualMachine
            ? ''
            : _historyRootController.text.trim(),
        location: _usesVirtualMachine ? 'virtual-machine' : 'local',
        runtimeConnection: _usesVirtualMachine
            ? <String, dynamic>{
                'kind': 'ssh',
                'host': _hostController.text.trim(),
                'port': ?port,
                if (user.isNotEmpty) 'user': user,
                'remoteExecutable': _remoteExecutableController.text.trim(),
                'workingDirectory': _remoteWorkingDirectoryController.text
                    .trim(),
              }
            : const <String, dynamic>{},
      ),
    );
  }

  String? _requiredSshValue(String? value, LicoStrings strings) {
    final normalized = value?.trim() ?? '';
    if (normalized.isEmpty) return strings.fieldRequired;
    return _isSafeSshHost(normalized) ? null : strings.invalidSshValue;
  }

  String? _requiredRemoteValue(String? value, LicoStrings strings) {
    final normalized = value?.trim() ?? '';
    if (normalized.isEmpty) return strings.fieldRequired;
    return !normalized.startsWith('-') &&
            normalized.length <= 1024 &&
            !normalized.contains(RegExp(r'[\r\n\u0000]'))
        ? null
        : strings.invalidSshValue;
  }

  bool _isSafeSshHost(String value) =>
      !value.startsWith('-') &&
      value.length <= 255 &&
      RegExp(r'^[A-Za-z0-9._:\[\]-]+$').hasMatch(value);

  bool _isSafeSshUser(String value) =>
      !value.startsWith('-') &&
      value.length <= 255 &&
      RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(value);

  Future<void> _openDirectory(String path) async {
    final opener = widget.onOpenDirectory;
    if (opener == null) {
      return;
    }
    await opener(path);
  }
}
