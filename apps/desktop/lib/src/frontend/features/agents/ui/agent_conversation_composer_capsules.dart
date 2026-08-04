import 'dart:async';

import 'package:flutter/material.dart';

import 'package:licoup/src/application/features/agents/conversation/conversation_working_directory_fallback.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_conversation_overlay_glass.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_hover_popover.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/apple_control_metrics.dart';
import 'package:licoup/src/frontend/shared/ui/apple_glass.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Stadium ends for messaging composer context capsules.
const BorderRadius kComposerCapsuleBorderRadius = BorderRadius.all(
  Radius.circular(999),
);

/// Glass capsule row pinned directly above the messaging composer: workspace
/// directory and/or runtime selection (model + effort), sharing one inset band.
class ComposerCapsuleRow extends StatelessWidget {
  const ComposerCapsuleRow({
    super.key,
    this.workingDirectory,
    this.workingDirectorySelectable = false,
    this.onChooseWorkingDirectory,
    this.modelOptions = const [],
    this.selectedModel = '',
    this.defaultModel = '',
    this.modelSelectionEnabled = true,
    this.onModelChanged,
    this.reasoningEffortOptions = const [],
    this.selectedReasoningEffort = '',
    this.onReasoningEffortChanged,
  });

  final String? workingDirectory;
  final bool workingDirectorySelectable;
  final VoidCallback? onChooseWorkingDirectory;
  final List<String> modelOptions;
  final String selectedModel;
  final String defaultModel;
  final bool modelSelectionEnabled;
  final ValueChanged<String>? onModelChanged;
  final List<String> reasoningEffortOptions;
  final String selectedReasoningEffort;
  final ValueChanged<String>? onReasoningEffortChanged;

  bool get _showWorkspace {
    final path = workingDirectory?.trim() ?? '';
    return path.isNotEmpty;
  }

  bool get _showRuntimeSelector =>
      modelOptions.isNotEmpty || reasoningEffortOptions.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    if (!_showWorkspace && !_showRuntimeSelector) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (_showWorkspace)
              ComposerWorkspaceCapsule(
                workingDirectory: workingDirectory!.trim(),
                selectable: workingDirectorySelectable,
                onChoose: onChooseWorkingDirectory,
              ),
            if (_showRuntimeSelector)
              ComposerRuntimeCapsule(
                modelOptions: modelOptions,
                selectedModel: selectedModel,
                defaultModel: defaultModel,
                enabled: modelSelectionEnabled,
                onModelChanged: onModelChanged,
                reasoningEffortOptions: reasoningEffortOptions,
                selectedReasoningEffort: selectedReasoningEffort,
                onReasoningEffortChanged: onReasoningEffortChanged,
              ),
          ],
        ),
      ),
    );
  }
}

/// Workspace directory capsule — shortened path with folder / lock affordance.
class ComposerWorkspaceCapsule extends StatelessWidget {
  const ComposerWorkspaceCapsule({
    super.key,
    required this.workingDirectory,
    required this.selectable,
    required this.onChoose,
  });

  final String workingDirectory;
  final bool selectable;
  final VoidCallback? onChoose;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final fullPath = workingDirectory.trim();
    final display = shortenComposerWorkspacePath(fullPath);
    final canChoose = selectable && onChoose != null;
    final splitAt = display.lastIndexOf('/');
    final head = splitAt <= 0 ? '' : display.substring(0, splitAt + 1);
    final base = splitAt <= 0 ? display : display.substring(splitAt + 1);
    return Tooltip(
      message: fullPath,
      waitDuration: const Duration(milliseconds: 400),
      child: Semantics(
        button: true,
        enabled: canChoose,
        label: '${strings.workingDirectory}: $display',
        child: AppleGlassSurface(
          borderRadius: kComposerCapsuleBorderRadius,
          fillAlpha: colors.isDark ? (canChoose ? 22 : 12) : 10,
          child: InkWell(
            key: const Key('conversation-workspace-button'),
            onTap: canChoose ? onChoose : null,
            borderRadius: kComposerCapsuleBorderRadius,
            mouseCursor: canChoose
                ? SystemMouseCursors.click
                : SystemMouseCursors.basic,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    canChoose
                        ? Icons.folder_open_outlined
                        : Icons.folder_outlined,
                    size: 15,
                    color: canChoose
                        ? colors.primaryStrong
                        : colors.textMuted.withAlpha(140),
                  ),
                  const SizedBox(width: 7),
                  Flexible(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          if (head.isNotEmpty)
                            TextSpan(
                              text: head,
                              style: TextStyle(
                                color: colors.textMuted.withAlpha(170),
                              ),
                            ),
                          TextSpan(
                            text: base,
                            style: TextStyle(
                              color: canChoose
                                  ? colors.text.withAlpha(235)
                                  : colors.textMuted.withAlpha(200),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                        letterSpacing: -0.08,
                        height: 1.15,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (!canChoose) ...[
                    const SizedBox(width: 6),
                    Icon(
                      Icons.lock_outline_rounded,
                      size: 12.5,
                      color: colors.textMuted.withAlpha(120),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Runtime selector capsule — compact model + effort summary with a cascading
/// hover menu for model and reasoning effort. Hidden when no catalogs exist.
class ComposerRuntimeCapsule extends StatelessWidget {
  const ComposerRuntimeCapsule({
    super.key,
    required this.modelOptions,
    required this.selectedModel,
    required this.defaultModel,
    required this.enabled,
    required this.onModelChanged,
    required this.reasoningEffortOptions,
    required this.selectedReasoningEffort,
    required this.onReasoningEffortChanged,
  });

  final List<String> modelOptions;
  final String selectedModel;
  final String defaultModel;
  final bool enabled;
  final ValueChanged<String>? onModelChanged;
  final List<String> reasoningEffortOptions;
  final String selectedReasoningEffort;
  final ValueChanged<String>? onReasoningEffortChanged;

  bool get _menuEnabled =>
      enabled &&
      ((modelOptions.isNotEmpty && onModelChanged != null) ||
          (reasoningEffortOptions.isNotEmpty &&
              onReasoningEffortChanged != null));

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final effectiveDefault = _effectiveDefaultModel(modelOptions, defaultModel);
    final activeEffort =
        reasoningEffortOptions.contains(selectedReasoningEffort.trim())
        ? selectedReasoningEffort.trim()
        : '';
    final capsuleLabel = composeRuntimeCapsuleLabel(
      model: _runtimeModelDisplayLabel(
        modelOptions: modelOptions,
        selectedModel: selectedModel,
        nativeDefaultLabel: strings.nativeDefault,
      ),
      // An unset effort adds nothing to the capsule; the model already reads as
      // the agent's own default.
      effort: activeEffort.isEmpty
          ? ''
          : _runtimeEffortOptionLabel(strings, activeEffort),
    );
    final tooltip = capsuleLabel.isEmpty
        ? strings.model
        : '${strings.model}: $capsuleLabel';

    if (!_menuEnabled) {
      return _RuntimeCapsuleTrigger(
        label: capsuleLabel.isEmpty ? strings.model : capsuleLabel,
        menuEnabled: false,
        tooltip: tooltip,
      );
    }

    final menuRadius = BorderRadius.circular(
      AppleControlMetrics.menuCornerRadius,
    );
    // Stick flush above the capsule; body supplies two detached glass cards
    // (primary stays fixed; submenu appears to the right with a gap).
    return MessagingHoverPopover(
      popoverKey: const Key('conversation-runtime-selector-panel'),
      targetAnchor: Alignment.topLeft,
      followerAnchor: Alignment.bottomLeft,
      offset: const Offset(0, -4),
      maxHeight:
          MessagingDesktopMetrics.composerRuntimeSelectorPopoverMaxHeight,
      borderRadius: menuRadius,
      wrapInGlass: false,
      readabilityVeil: true,
      cardBuilder: (context, close) {
        return _ComposerRuntimeSelectorPanel(
          borderRadius: menuRadius,
          modelOptions: modelOptions,
          selectedModel: selectedModel,
          defaultModel: effectiveDefault,
          onModelChanged: onModelChanged == null
              ? null
              : (value) {
                  onModelChanged!(value);
                  close();
                },
          reasoningEffortOptions: reasoningEffortOptions,
          selectedReasoningEffort: selectedReasoningEffort,
          onReasoningEffortChanged: onReasoningEffortChanged == null
              ? null
              : (value) {
                  onReasoningEffortChanged!(value);
                  close();
                },
        );
      },
      triggerBuilder:
          (context, {required open, required toggle, required close}) {
            return _RuntimeCapsuleTrigger(
              label: capsuleLabel.isEmpty ? strings.model : capsuleLabel,
              menuEnabled: true,
              tooltip: tooltip,
              open: open,
              onTap: toggle,
            );
          },
    );
  }
}

class _RuntimeCapsuleTrigger extends StatelessWidget {
  const _RuntimeCapsuleTrigger({
    required this.label,
    required this.menuEnabled,
    required this.tooltip,
    this.open = false,
    this.onTap,
  });

  final String label;
  final bool menuEnabled;
  final String tooltip;
  final bool open;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: Semantics(
        button: true,
        enabled: menuEnabled,
        label: tooltip,
        child: AppleGlassSurface(
          borderRadius: kComposerCapsuleBorderRadius,
          fillAlpha: colors.isDark ? (menuEnabled ? 22 : 12) : 10,
          child: InkWell(
            key: const Key('conversation-model-button'),
            onTap: menuEnabled ? onTap : null,
            borderRadius: kComposerCapsuleBorderRadius,
            mouseCursor: menuEnabled
                ? SystemMouseCursors.click
                : SystemMouseCursors.basic,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.auto_awesome_outlined,
                    size: 15,
                    color: menuEnabled
                        ? colors.primaryStrong
                        : colors.textMuted.withAlpha(140),
                  ),
                  const SizedBox(width: 7),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: menuEnabled
                            ? colors.text.withAlpha(235)
                            : colors.textMuted.withAlpha(200),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.08,
                        height: 1.15,
                      ),
                    ),
                  ),
                  if (menuEnabled) ...[
                    const SizedBox(width: 4),
                    Icon(
                      open
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 15,
                      color: colors.textMuted.withAlpha(160),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _RuntimeSelectorSection { model, effort }

class _ComposerRuntimeSelectorPanel extends StatefulWidget {
  const _ComposerRuntimeSelectorPanel({
    required this.borderRadius,
    required this.modelOptions,
    required this.selectedModel,
    required this.defaultModel,
    required this.onModelChanged,
    required this.reasoningEffortOptions,
    required this.selectedReasoningEffort,
    required this.onReasoningEffortChanged,
  });

  final BorderRadius borderRadius;
  final List<String> modelOptions;
  final String selectedModel;
  final String defaultModel;
  final ValueChanged<String>? onModelChanged;
  final List<String> reasoningEffortOptions;
  final String selectedReasoningEffort;
  final ValueChanged<String>? onReasoningEffortChanged;

  @override
  State<_ComposerRuntimeSelectorPanel> createState() =>
      _ComposerRuntimeSelectorPanelState();
}

class _ComposerRuntimeSelectorPanelState
    extends State<_ComposerRuntimeSelectorPanel> {
  _RuntimeSelectorSection? _hoveredSection;
  _RuntimeSelectorSection? _pinnedSection;
  Timer? _sectionDismissTimer;

  static const Duration _sectionDismissGrace = Duration(milliseconds: 180);

  _RuntimeSelectorSection? get _activeSection =>
      _pinnedSection ?? _hoveredSection;

  @override
  void dispose() {
    _sectionDismissTimer?.cancel();
    super.dispose();
  }

  void _onSectionEnter(_RuntimeSelectorSection section) {
    _sectionDismissTimer?.cancel();
    setState(() => _hoveredSection = section);
  }

  void _onSectionExit() {
    _sectionDismissTimer?.cancel();
    _sectionDismissTimer = Timer(_sectionDismissGrace, () {
      if (!mounted || _pinnedSection != null) {
        return;
      }
      setState(() => _hoveredSection = null);
    });
  }

  void _onSectionTap(_RuntimeSelectorSection section) {
    _sectionDismissTimer?.cancel();
    setState(() {
      if (_pinnedSection == section) {
        _pinnedSection = null;
      } else {
        _pinnedSection = section;
      }
      _hoveredSection = section;
    });
  }

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final modelDisplay = _runtimeModelDisplayLabel(
      modelOptions: widget.modelOptions,
      selectedModel: widget.selectedModel,
      nativeDefaultLabel: strings.nativeDefault,
    );
    final activeEffort =
        widget.reasoningEffortOptions.contains(
          widget.selectedReasoningEffort.trim(),
        )
        ? widget.selectedReasoningEffort.trim()
        : '';
    final effortDisplay = _runtimeEffortOptionLabel(strings, activeEffort);

    // Primary card width is fixed. Submenu is a second glass card with a gap —
    // hovering a row must not grow or reshape the primary card.
    final primary = MessagingConversationOverlayGlass(
      key: const Key('conversation-runtime-primary-card'),
      borderRadius: widget.borderRadius,
      readabilityVeil: true,
      child: SizedBox(
        width: MessagingDesktopMetrics.composerRuntimeSelectorPrimaryWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.modelOptions.isNotEmpty)
              _RuntimeSelectorPrimaryRow(
                key: const Key('conversation-runtime-model-row'),
                label: strings.model,
                value: modelDisplay,
                active: _activeSection == _RuntimeSelectorSection.model,
                onEnter: () => _onSectionEnter(_RuntimeSelectorSection.model),
                onTap: () => _onSectionTap(_RuntimeSelectorSection.model),
              ),
            if (widget.reasoningEffortOptions.isNotEmpty)
              _RuntimeSelectorPrimaryRow(
                key: const Key('conversation-runtime-effort-row'),
                label: strings.reasoningEffort,
                value: effortDisplay,
                active: _activeSection == _RuntimeSelectorSection.effort,
                onEnter: () => _onSectionEnter(_RuntimeSelectorSection.effort),
                onTap: () => _onSectionTap(_RuntimeSelectorSection.effort),
              ),
          ],
        ),
      ),
    );

    final submenu = _activeSection == null
        ? null
        : MouseRegion(
            onEnter: (_) => _sectionDismissTimer?.cancel(),
            onExit: (_) => _onSectionExit(),
            child: MessagingConversationOverlayGlass(
              key: const Key('conversation-runtime-submenu'),
              borderRadius: widget.borderRadius,
              readabilityVeil: true,
              child: SizedBox(
                width:
                    MessagingDesktopMetrics.composerRuntimeSelectorSubmenuWidth,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxHeight: MessagingDesktopMetrics
                        .composerRuntimeSelectorSubmenuMaxHeight,
                  ),
                  child: _buildSubmenu(context),
                ),
              ),
            ),
          );

    // CrossAxisAlignment.end keeps both cards on one baseline so the hover
    // popover's bottomLeft anchor sticks to the capsule. Start-alignment made
    // a tall submenu lift the primary card into mid-chat.
    return MouseRegion(
      onExit: (_) => _onSectionExit(),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          primary,
          if (submenu != null) ...[
            const SizedBox(
              width: MessagingDesktopMetrics.composerRuntimeSelectorSubmenuGap,
            ),
            submenu,
          ],
        ],
      ),
    );
  }

  Widget _buildSubmenu(BuildContext context) {
    final strings = LicoStrings.of(context);
    final section = _activeSection;
    if (section == _RuntimeSelectorSection.model &&
        widget.modelOptions.isNotEmpty) {
      final effectiveDefault = widget.defaultModel;
      final selectedMenuValue = _selectedMenuValue(
        modelOptions: widget.modelOptions,
        selectedModel: widget.selectedModel,
        defaultModel: effectiveDefault,
      );
      return _RuntimeSelectorSubmenuList(
        children: [
          for (final option in widget.modelOptions)
            _RuntimeSelectorOptionRow(
              label: option == effectiveDefault
                  ? strings.defaultValueDisplay(
                      shortenComposerModelName(option),
                    )
                  : shortenComposerModelName(option),
              selected:
                  (option == effectiveDefault ? '' : option) ==
                  selectedMenuValue,
              onTap: widget.onModelChanged == null
                  ? null
                  : () => widget.onModelChanged!(
                      option == effectiveDefault ? '' : option,
                    ),
            ),
        ],
      );
    }
    if (section == _RuntimeSelectorSection.effort &&
        widget.reasoningEffortOptions.isNotEmpty) {
      final selected =
          widget.reasoningEffortOptions.contains(
            widget.selectedReasoningEffort.trim(),
          )
          ? widget.selectedReasoningEffort.trim()
          : '';
      return _RuntimeSelectorSubmenuList(
        children: [
          // Leading row returns the turn to the agent's own effort default.
          _RuntimeSelectorOptionRow(
            label: _runtimeEffortOptionLabel(strings, ''),
            selected: selected.isEmpty,
            onTap: widget.onReasoningEffortChanged == null
                ? null
                : () => widget.onReasoningEffortChanged!(''),
          ),
          for (final option in widget.reasoningEffortOptions)
            _RuntimeSelectorOptionRow(
              label: _runtimeEffortOptionLabel(strings, option),
              selected: option == selected,
              onTap: widget.onReasoningEffortChanged == null
                  ? null
                  : () => widget.onReasoningEffortChanged!(option),
            ),
        ],
      );
    }
    return const SizedBox.shrink();
  }
}

class _RuntimeSelectorPrimaryRow extends StatelessWidget {
  const _RuntimeSelectorPrimaryRow({
    super.key,
    required this.label,
    required this.value,
    required this.active,
    required this.onEnter,
    required this.onTap,
  });

  final String label;
  final String value;
  final bool active;
  final VoidCallback onEnter;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return MouseRegion(
      onEnter: (_) => onEnter(),
      child: Material(
        color: active
            ? (colors.isDark
                  ? Colors.white.withAlpha(10)
                  : Colors.black.withAlpha(8))
            : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: Row(
              children: [
                // The control name keeps the larger share so a two-word label
                // stays on one line; the current value absorbs the remainder.
                Expanded(
                  flex: 3,
                  child: Text(
                    label,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.text,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      color: colors.textMuted,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 16,
                  color: colors.textMuted.withAlpha(180),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RuntimeSelectorSubmenuList extends StatelessWidget {
  const _RuntimeSelectorSubmenuList({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

class _RuntimeSelectorOptionRow extends StatelessWidget {
  const _RuntimeSelectorOptionRow({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Material(
      color: selected
          ? (colors.isDark
                ? Colors.white.withAlpha(10)
                : Colors.black.withAlpha(8))
          : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.text,
                    fontSize: 12.5,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ),
              if (selected) ...[
                const SizedBox(width: 6),
                Icon(Icons.check_rounded, size: 15, color: colors.accent),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Back-compat alias — prefer [ComposerRuntimeCapsule].
typedef ComposerModelCapsule = ComposerRuntimeCapsule;

String _effectiveDefaultModel(List<String> options, String defaultModel) {
  final normalized = defaultModel.trim();
  return options.contains(normalized) ? normalized : '';
}

/// The explicitly selected model, or empty when the conversation runs on the
/// agent's own default selection (Auto).
String _activeModelName({
  required List<String> modelOptions,
  required String selectedModel,
}) {
  final trimmed = selectedModel.trim();
  return trimmed.isNotEmpty && modelOptions.contains(trimmed) ? trimmed : '';
}

/// Capsule and menu-row text for the runtime model. An empty selection reads as
/// the agent's own default (Auto) instead of borrowing the catalog default name,
/// so the label always matches the checked menu row.
String _runtimeModelDisplayLabel({
  required List<String> modelOptions,
  required String selectedModel,
  required String nativeDefaultLabel,
}) {
  final active = _activeModelName(
    modelOptions: modelOptions,
    selectedModel: selectedModel,
  );
  if (active.isNotEmpty) {
    return shortenComposerModelName(active);
  }
  return modelOptions.isEmpty ? '' : nativeDefaultLabel;
}

/// Localized display text for one reasoning-effort token, falling back to the
/// title-cased token when the catalog reports a value the product has no
/// translation for.
String _runtimeEffortOptionLabel(LicoStrings strings, String effort) {
  final trimmed = effort.trim();
  return strings.reasoningEffortOptionLabel(
    trimmed,
    formatComposerReasoningEffortLabel(trimmed),
  );
}

String _selectedMenuValue({
  required List<String> modelOptions,
  required String selectedModel,
  required String defaultModel,
}) {
  final trimmed = selectedModel.trim();
  if (trimmed.isNotEmpty &&
      trimmed != defaultModel &&
      modelOptions.contains(trimmed)) {
    return trimmed;
  }
  if (defaultModel.isNotEmpty) {
    return '';
  }
  return trimmed.isNotEmpty && modelOptions.contains(trimmed) ? trimmed : '';
}

/// Compact capsule label: short model name plus short effort when both exist.
String composeRuntimeCapsuleLabel({
  required String model,
  required String effort,
}) {
  final parts = <String>[];
  final shortModel = shortenComposerModelName(model);
  if (shortModel.isNotEmpty) {
    parts.add(shortModel);
  }
  if (effort.isNotEmpty) {
    parts.add(formatComposerReasoningEffortLabel(effort));
  }
  return parts.join(' ');
}

/// Title-cases a reasoning-effort token for capsule and menu display.
String formatComposerReasoningEffortLabel(String effort) {
  final trimmed = effort.trim();
  if (trimmed.isEmpty) {
    return trimmed;
  }
  if (trimmed.length == 1) {
    return trimmed.toUpperCase();
  }
  return '${trimmed[0].toUpperCase()}${trimmed.substring(1)}';
}

/// Shortens an absolute workspace path for the composer capsule.
String shortenComposerWorkspacePath(String path) {
  final home = userHomeDirectory();
  var display = path;
  if (home.isNotEmpty) {
    if (path == home) {
      display = '~';
    } else if (path.startsWith('$home/')) {
      display = '~${path.substring(home.length)}';
    }
  }
  final segments = display.split('/')..removeWhere((s) => s.isEmpty);
  if (display.length <= 38 || segments.length <= 2) {
    return display;
  }
  final last = segments.last;
  if (display.startsWith('~/')) {
    return '~/…/$last';
  }
  if (display.startsWith('/')) {
    return '/${segments.first}/…/$last';
  }
  return '${segments.first}/…/$last';
}

/// Collapses a model id to a glanceable short label for the composer capsule.
String shortenComposerModelName(String model) {
  final trimmed = model.trim();
  if (trimmed.isEmpty) {
    return trimmed;
  }
  final slash = trimmed.lastIndexOf('/');
  final base = slash >= 0 ? trimmed.substring(slash + 1) : trimmed;
  if (base.length <= 28) {
    return base;
  }
  return '${base.substring(0, 25)}…';
}
