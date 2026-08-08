import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/apple_control_metrics.dart';
import 'package:licoup/src/frontend/shared/ui/apple_glass.dart';
import 'package:licoup/src/frontend/shared/ui/apple_popup_select.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

class ConversationRuntimeSettingsBar extends StatelessWidget {
  const ConversationRuntimeSettingsBar({
    super.key,
    required this.enabled,
    required this.modelOptions,
    required this.selectedModel,
    required this.reasoningEffortOptions,
    required this.selectedReasoningEffort,
    required this.onModelChanged,
    required this.onReasoningEffortChanged,
    this.defaultModel = '',
    this.defaultReasoningEffort = '',
    this.showWorkingDirectory = false,
    this.workingDirectory = '',
    this.workingDirectorySelectable = false,
    this.onChooseWorkingDirectory,
  });

  final bool enabled;
  final List<String> modelOptions;
  final String selectedModel;
  final List<String> reasoningEffortOptions;
  final String selectedReasoningEffort;
  final ValueChanged<String> onModelChanged;
  final ValueChanged<String> onReasoningEffortChanged;
  final String defaultModel;
  final String defaultReasoningEffort;
  final bool showWorkingDirectory;
  final String workingDirectory;
  final bool workingDirectorySelectable;
  final VoidCallback? onChooseWorkingDirectory;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final model = modelOptions.contains(selectedModel) ? selectedModel : '';
    final reasoning = reasoningEffortOptions.contains(selectedReasoningEffort)
        ? selectedReasoningEffort
        : '';
    final effortDefault = () {
      final configured = defaultReasoningEffort.trim();
      if (configured.isNotEmpty &&
          reasoningEffortOptions.contains(configured)) {
        return configured;
      }
      return reasoningEffortOptions.isEmpty ? '' : reasoningEffortOptions.first;
    }();
    final effortDefaultLabel = effortDefault.isEmpty
        ? strings.defaultModelUnavailable
        : strings.reasoningEffortOptionLabel(effortDefault, effortDefault);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (modelOptions.isNotEmpty)
          _RuntimeModelSelect(
            key: const ValueKey('conversation-model-select'),
            value: model,
            options: modelOptions,
            enabled: enabled,
            defaultModel: defaultModel,
            onChanged: onModelChanged,
          ),
        if (reasoningEffortOptions.isNotEmpty)
          _RuntimeSettingSelect(
            key: const ValueKey('conversation-reasoning-select'),
            label: strings.reasoningSetting,
            value: reasoning,
            options: reasoningEffortOptions,
            enabled: enabled,
            defaultLabel: effortDefaultLabel,
            onChanged: onReasoningEffortChanged,
          ),
        if (showWorkingDirectory)
          ConversationWorkingDirectoryControl(
            key: const ValueKey('conversation-working-directory-select'),
            workingDirectory: workingDirectory,
            enabled: workingDirectorySelectable,
            onPressed: onChooseWorkingDirectory,
          ),
      ],
    );
  }
}

class _RuntimeModelSelect extends StatelessWidget {
  const _RuntimeModelSelect({
    super.key,
    required this.value,
    required this.options,
    required this.enabled,
    required this.defaultModel,
    required this.onChanged,
  });

  final String value;
  final List<String> options;
  final bool enabled;
  final String defaultModel;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final normalizedDefault = defaultModel.trim();
    final effectiveDefault = options.contains(normalizedDefault)
        ? normalizedDefault
        : '';
    final selectedModel = options.contains(value) ? value : '';
    final String? selectedOptionValue = switch ((
      selectedModel,
      effectiveDefault,
    )) {
      (final selected, _)
          when selected.isNotEmpty && selected != effectiveDefault =>
        selected,
      (_, final model) when model.isNotEmpty => '',
      _ => null,
    };

    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 150, maxWidth: 240),
      child: ApplePopupSelect<String>(
        value: selectedOptionValue,
        hint: strings.defaultModelUnavailable,
        isExpanded: true,
        dense: true,
        enabled: enabled,
        options: [
          for (final option in options)
            ApplePopupSelectOption(
              value: option == effectiveDefault ? '' : option,
              label: option == effectiveDefault
                  ? strings.defaultValueDisplay(option)
                  : option,
            ),
        ],
        onChanged: enabled ? onChanged : null,
      ),
    );
  }
}

class _RuntimeSettingSelect extends StatelessWidget {
  const _RuntimeSettingSelect({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.enabled,
    required this.defaultLabel,
    required this.onChanged,
  });

  final String label;
  final String value;
  final List<String> options;
  final bool enabled;
  final String defaultLabel;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 150, maxWidth: 240),
      child: ApplePopupSelect<String>(
        value: value,
        isExpanded: true,
        dense: true,
        enabled: enabled,
        options: [
          ApplePopupSelectOption(value: '', label: '$label · $defaultLabel'),
          for (final option in options)
            ApplePopupSelectOption(value: option, label: '$label · $option'),
        ],
        onChanged: enabled ? onChanged : null,
      ),
    );
  }
}

class ConversationWorkingDirectoryControl extends StatelessWidget {
  const ConversationWorkingDirectoryControl({
    super.key,
    required this.workingDirectory,
    required this.enabled,
    required this.onPressed,
  });

  final String workingDirectory;
  final bool enabled;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final normalized = workingDirectory.trim();
    final canChoose = enabled && onPressed != null;
    final basename = p.basename(normalized);
    final directoryLabel = normalized.isEmpty
        ? strings.chooseWorkingDirectory
        : basename.isEmpty
        ? normalized
        : basename;
    final tooltip = normalized.isEmpty
        ? strings.chooseWorkingDirectory
        : canChoose
        ? '${strings.changeWorkingDirectory}\n$normalized'
        : '${strings.workingDirectoryFixedForSession}\n$normalized';
    final textColor = canChoose
        ? colors.text.withAlpha(235)
        : colors.textMuted.withAlpha(140);

    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 180, maxWidth: 320),
      child: Tooltip(
        message: tooltip,
        waitDuration: const Duration(milliseconds: 400),
        child: Semantics(
          button: true,
          enabled: canChoose,
          label: '${strings.workingDirectory}: $directoryLabel',
          child: AppleGlassSurface(
            borderRadius: BorderRadius.circular(
              AppleControlMetrics.controlCornerRadius,
            ),
            fillAlpha: colors.isDark ? (canChoose ? 22 : 12) : 10,
            child: InkWell(
              onTap: canChoose ? onPressed : null,
              mouseCursor: canChoose
                  ? SystemMouseCursors.click
                  : SystemMouseCursors.basic,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 5, 8, 5),
                child: Row(
                  children: [
                    Icon(
                      canChoose
                          ? Icons.folder_open_outlined
                          : Icons.folder_outlined,
                      size: 15,
                      color: canChoose
                          ? colors.primaryStrong
                          : colors.textMuted.withAlpha(110),
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        '${strings.workingDirectory} · $directoryLabel',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: textColor,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          letterSpacing: -0.08,
                          height: 1.15,
                        ),
                      ),
                    ),
                    if (!canChoose) ...[
                      const SizedBox(width: 6),
                      Icon(
                        Icons.lock_outline_rounded,
                        size: 13,
                        color: colors.textMuted.withAlpha(100),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
