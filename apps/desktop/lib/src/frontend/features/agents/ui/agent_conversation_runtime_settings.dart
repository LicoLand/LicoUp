import 'package:flutter/material.dart';

import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/shared/ui/apple_popup_select.dart';

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
  });

  final bool enabled;
  final List<String> modelOptions;
  final String selectedModel;
  final List<String> reasoningEffortOptions;
  final String selectedReasoningEffort;
  final ValueChanged<String> onModelChanged;
  final ValueChanged<String> onReasoningEffortChanged;
  final String defaultModel;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final model = modelOptions.contains(selectedModel) ? selectedModel : '';
    final reasoning = reasoningEffortOptions.contains(selectedReasoningEffort)
        ? selectedReasoningEffort
        : '';
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (modelOptions.isNotEmpty)
          _RuntimeSettingSelect(
            key: const ValueKey('conversation-model-select'),
            label: strings.model,
            value: model,
            options: modelOptions,
            enabled: enabled,
            defaultLabel: defaultModel.isEmpty
                ? strings.nativeDefault
                : strings.defaultValueDisplay(defaultModel),
            onChanged: onModelChanged,
          ),
        if (reasoningEffortOptions.isNotEmpty)
          _RuntimeSettingSelect(
            key: const ValueKey('conversation-reasoning-select'),
            label: strings.reasoningSetting,
            value: reasoning,
            options: reasoningEffortOptions,
            enabled: enabled,
            defaultLabel: strings.nativeDefault,
            onChanged: onReasoningEffortChanged,
          ),
      ],
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
          ApplePopupSelectOption(
            value: '',
            label: '$label · $defaultLabel',
          ),
          for (final option in options)
            ApplePopupSelectOption(value: option, label: '$label · $option'),
        ],
        onChanged: enabled ? onChanged : null,
      ),
    );
  }
}
