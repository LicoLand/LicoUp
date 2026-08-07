import 'dart:async';

import 'package:flutter/material.dart';

import 'package:licoup/src/application/composition/agent_resource_usage_gateway_adapter.dart';
import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/layout/layout_state_store.dart';
import 'package:licoup/src/contracts/locale_preferences.dart';
import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/frontend/features/settings/ui/agent_resource_usage_card.dart';
import 'package:licoup/src/frontend/features/settings/ui/client_update_settings_card.dart';
import 'package:licoup/src/frontend/features/settings/ui/layout_profile_selector.dart';
import 'package:licoup/src/frontend/features/settings/ui/catalog_convergence_status_card.dart';
import 'package:licoup/src/frontend/features/settings/ui/client_resource_usage_card.dart';
import 'package:licoup/src/frontend/features/settings/ui/settings_log_export_tile.dart';
import 'package:licoup/src/frontend/features/settings/ui/settings_panel_widgets.dart';
import 'package:licoup/src/frontend/features/settings/ui/settings_section_catalog.dart';
import 'package:licoup/src/frontend/features/settings/ui/startup_autostart_card.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_pane/resize.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/layout/layout_scope.dart';
import 'package:licoup/src/frontend/shared/appearance/appearance_preset_config.dart';
import 'package:licoup/src/frontend/shared/platform/client_platform.dart';
import 'package:licoup/src/frontend/shared/ui/directory_path_field.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

const _settingsSectionIds = settingsSectionIdOrder;

/// Settings index rail bounds. The rail defaults to the narrowest usable
/// width and the user drags the split divider wider, mirroring the
/// conversation-list sidebar in the agents workspace.
const double _settingsIndexMinWidth = 120;
const double _settingsIndexMaxWidth = 360;
const double _settingsIndexDividerWidth = 8;
const double _settingsMinContentWidth = 360;

class SettingsPanel extends StatefulWidget {
  const SettingsPanel({super.key, required this.controller});

  final ClientController controller;

  @override
  State<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<SettingsPanel> {
  final _scrollController = ScrollController();
  final _contentKey = GlobalKey();
  final _sectionKeys = <String, GlobalKey>{};
  String? _selectedSectionId;
  LayoutScopedState? _layoutState;
  String? _layoutStateIdentity;
  Listenable? _layoutStateChanges;
  double? _pendingScrollOffset;
  // Default to the narrowest usable rail; users can drag wider.
  double _indexWidth = _settingsIndexMinWidth;
  DateTime _settleSuppressedUntil = DateTime.fromMillisecondsSinceEpoch(0);
  bool _settling = false;
  bool _jumpInFlight = false;

  /// Distance from a section start (in logical pixels) within which a
  /// finished scroll gently settles onto that start — the light "paging"
  /// feel, without trapping free scrolling mid-section.
  static const double _settleThreshold = 40;

  /// Vertical distance from the viewport top within which a section counts
  /// as the active one for the scroll-spy.
  static const double _spyThreshold = 80;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handleScroll);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = LayoutScope.maybeOf(context);
    if (scope == null) {
      _unwatchLayoutState();
      _layoutState = null;
      _layoutStateIdentity = null;
      _pendingScrollOffset = null;
      return;
    }
    final identity =
        '${scope.profileId.value}/${scope.environment.surface.name}';
    if (_layoutStateIdentity == identity) {
      return;
    }
    _unwatchLayoutState();
    _layoutStateIdentity = identity;
    _layoutState = scope.state;
    _layoutStateChanges = scope.state.changes
      ..addListener(_syncSelectionFromStore);

    final scroll = scope.state.readIfDeclared(
      LayoutStateChannels.settingsScroll,
    );
    final section = scope.state.readIfDeclared(
      LayoutStateChannels.settingsSection,
    );
    _selectedSectionId =
        section is LayoutTabState && section.index < _settingsSectionIds.length
        ? _settingsSectionIds[section.index]
        : null;
    final index = scope.state.readIfDeclared(LayoutStateChannels.settingsIndex);
    _indexWidth = index is LayoutPaneExtentState
        ? index.extent.clamp(_settingsIndexMinWidth, _settingsIndexMaxWidth)
        : _settingsIndexMinWidth;
    _pendingScrollOffset = scroll is LayoutScrollState ? scroll.offset : 0;
    WidgetsBinding.instance.addPostFrameCallback((_) => _restoreScrollOffset());
  }

  void _restoreScrollOffset() {
    final offset = _pendingScrollOffset;
    if (!mounted || offset == null || !_scrollController.hasClients) {
      return;
    }
    _pendingScrollOffset = null;
    _scrollController.jumpTo(
      offset.clamp(0, _scrollController.position.maxScrollExtent).toDouble(),
    );
  }

  void _handleScroll() {
    _persistScrollOffset();
    _updateSpySelection();
  }

  void _persistScrollOffset() {
    if (!_scrollController.hasClients) {
      return;
    }
    _layoutState?.writeIfDeclared(
      LayoutStateChannels.settingsScroll,
      LayoutScrollState(
        _scrollController.offset.clamp(0, double.infinity).toDouble(),
      ),
    );
  }

  /// Each section's start offset in scroll coordinates, in section order.
  List<(String, double)> _sectionOffsets() {
    final viewportBox = _contentKey.currentContext?.findRenderObject();
    if (viewportBox is! RenderBox ||
        !viewportBox.hasSize ||
        !_scrollController.hasClients) {
      return const [];
    }
    final viewportDy = viewportBox.localToGlobal(Offset.zero).dy;
    final offsets = <(String, double)>[];
    for (final id in _settingsSectionIds) {
      final sectionContext = _sectionKeys[id]?.currentContext;
      if (sectionContext == null) {
        continue;
      }
      final box = sectionContext.findRenderObject();
      if (box is! RenderBox || !box.hasSize) {
        continue;
      }
      final dy = box.localToGlobal(Offset.zero).dy;
      offsets.add((id, dy - viewportDy + _scrollController.offset));
    }
    return offsets;
  }

  /// Scroll-spy: the sidebar selection follows the section closest to the
  /// viewport's reading zone while the user scrolls.
  void _updateSpySelection() {
    // While a sidebar jump is animating, section geometry lags the scroll
    // offset by a frame; the tapped entry owns the selection until the jump
    // settles and reconciles once with fresh geometry.
    if (_jumpInFlight) {
      return;
    }
    final offsets = _sectionOffsets();
    if (offsets.isEmpty || !mounted) {
      return;
    }
    final offset = _scrollController.offset;
    var active = offsets.first.$1;
    for (final (id, top) in offsets) {
      if (top <= offset + _spyThreshold) {
        active = id;
      }
    }
    if (active == _selectedSectionId) {
      return;
    }
    setState(() => _selectedSectionId = active);
    final index = _settingsSectionIds.indexOf(active);
    if (index >= 0) {
      _layoutState?.writeIfDeclared(
        LayoutStateChannels.settingsSection,
        LayoutTabState(index),
      );
    }
  }

  bool _handleScrollEnd() {
    if (_settling || DateTime.now().isBefore(_settleSuppressedUntil)) {
      return false;
    }
    final offsets = _sectionOffsets();
    if (offsets.isEmpty || !_scrollController.hasClients) {
      return false;
    }
    final offset = _scrollController.offset;
    var nearest = offsets.first.$2;
    var nearestDistance = (nearest - offset).abs();
    for (final (_, top) in offsets) {
      final distance = (top - offset).abs();
      if (distance < nearestDistance) {
        nearest = top;
        nearestDistance = distance;
      }
    }
    if (nearestDistance <= 0.5 || nearestDistance > _settleThreshold) {
      return false;
    }
    _settling = true;
    unawaited(
      _scrollController
          .animateTo(
            nearest.clamp(0.0, _scrollController.position.maxScrollExtent),
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
          )
          .whenComplete(() => _settling = false),
    );
    return false;
  }

  GlobalKey _keyFor(String id) {
    return _sectionKeys.putIfAbsent(id, GlobalKey.new);
  }

  void _scrollTo(String id) {
    setState(() => _selectedSectionId = id);
    final index = _settingsSectionIds.indexOf(id);
    if (index >= 0) {
      _layoutState?.writeIfDeclared(
        LayoutStateChannels.settingsSection,
        LayoutTabState(index),
      );
    }
    // Sidebar jumps animate smoothly to the section start; the threshold
    // settle stays out of the way of the programmatic scroll.
    _settleSuppressedUntil = DateTime.now().add(
      const Duration(milliseconds: 700),
    );
    unawaited(_jumpToSection(id));
  }

  /// Jumps to a section even when the lazy list builder has disposed it:
  /// first travel to the edge in the section's direction so it builds, then
  /// settle exactly onto it.
  Future<void> _jumpToSection(String id) async {
    _jumpInFlight = true;
    try {
      await _travelToSection(id);
    } finally {
      _jumpInFlight = false;
      // One last spy pass against the settled geometry, in case the user
      // interrupted the jump or the landing zone resolves differently.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _updateSpySelection();
        }
      });
    }
  }

  Future<void> _travelToSection(String id) async {
    final context = _keyFor(id).currentContext;
    if (context != null) {
      await Scrollable.ensureVisible(
        context,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutQuart,
        alignment: 0.02,
      );
      return;
    }
    final targetIndex = _settingsSectionIds.indexOf(id);
    final known = _sectionOffsets();
    if (known.isEmpty || !_scrollController.hasClients) {
      return;
    }
    final firstKnownIndex = _settingsSectionIds.indexOf(known.first.$1);
    final lastKnownIndex = _settingsSectionIds.indexOf(known.last.$1);
    if (targetIndex < firstKnownIndex) {
      await _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    } else if (targetIndex > lastKnownIndex) {
      await _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    }
    if (!mounted) {
      return;
    }
    final lateContext = _keyFor(id).currentContext;
    if (lateContext == null || !lateContext.mounted) {
      return;
    }
    await Scrollable.ensureVisible(
      lateContext,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutQuart,
      alignment: 0.02,
    );
  }

  void _unwatchLayoutState() {
    _layoutStateChanges?.removeListener(_syncSelectionFromStore);
    _layoutStateChanges = null;
  }

  /// Picks up section selections made outside this panel (the shell
  /// navigation's Settings sub-items) through the shared section tab channel.
  void _syncSelectionFromStore() {
    final state = _layoutState;
    if (state == null || !mounted) {
      return;
    }
    final section = state.readIfDeclared(LayoutStateChannels.settingsSection);
    if (section is! LayoutTabState ||
        section.index >= _settingsSectionIds.length) {
      return;
    }
    final id = _settingsSectionIds[section.index];
    if (id == _selectedSectionId) {
      return;
    }
    _scrollTo(id);
  }

  @override
  void dispose() {
    _unwatchLayoutState();
    _scrollController
      ..removeListener(_handleScroll)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mobileClient = isMobileClientPlatform(context);

    if (mobileClient) {
      return _MobileSettingsBody(
        controller: widget.controller,
        scrollController: _scrollController,
      );
    }

    final sections = _buildSections(context);
    final presentation = LayoutDestinationPresentationScope.settingsOf(context);

    // The profile's shell navigation hosts the section index (sub-items under
    // Settings), so the content runs full width; the section tab channel
    // keeps both sides on the same selection.
    if (presentation.indexHostedByNavigation) {
      return _buildContentScroll(sections, presentation);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxIndexWidth =
            (constraints.maxWidth -
                    _settingsIndexDividerWidth -
                    _settingsMinContentWidth)
                .clamp(_settingsIndexMinWidth, _settingsIndexMaxWidth)
                .toDouble();
        final indexWidth = _indexWidth
            .clamp(_settingsIndexMinWidth, maxIndexWidth)
            .toDouble();
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SettingsIndexSidebar(
              width: indexWidth,
              sections: sections,
              selectedId: _selectedSectionId ?? sections.first.id,
              onSelect: _scrollTo,
              presentation: presentation,
            ),
            Expanded(
              child: PaneEdgeDragHandle(
                dragHandleKey: const Key('settings-index-split-divider'),
                width: _settingsIndexDividerWidth,
                onDragDelta: (delta) {
                  setState(() {
                    _indexWidth = (indexWidth + delta)
                        .clamp(_settingsIndexMinWidth, maxIndexWidth)
                        .toDouble();
                  });
                  _layoutState?.writeIfDeclared(
                    LayoutStateChannels.settingsIndex,
                    LayoutPaneExtentState(_indexWidth),
                  );
                },
                child: _buildContentScroll(sections, presentation),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildContentScroll(
    List<_SettingsSection> sections,
    LayoutSettingsPresentation presentation,
  ) {
    return Scrollbar(
      key: _contentKey,
      controller: _scrollController,
      child: NotificationListener<ScrollEndNotification>(
        onNotification: (notification) => _handleScrollEnd(),
        child: ListView.builder(
          key: const Key('settings-content-scroll'),
          controller: _scrollController,
          padding: presentation.contentPadding,
          itemCount: sections.length * 2 - 1,
          itemBuilder: (context, index) {
            if (index.isOdd) {
              // One hairline between adjacent settings sections keeps the
              // canonical section order visually separated.
              return Divider(
                key: Key('settings-section-divider-${sections[index ~/ 2].id}'),
                height: 1,
                color: context.licoColors.line,
              );
            }
            final section = sections[index ~/ 2];
            return presentation.frameSection(
              context,
              key: _keyFor(section.id),
              child: section.child,
            );
          },
        ),
      ),
    );
  }

  List<_SettingsSection> _buildSections(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;

    // Navigation identity (icon and label) comes from the shared section
    // catalog so the shell navigation and any in-page rail never drift.
    Widget childFor(String id) => switch (id) {
      'appearance' => _AppearanceSettings(
        controller: widget.controller,
        colors: colors,
        strings: strings,
        surface: LayoutRuntimeSurface.desktop,
      ),
      'updates' => ClientUpdateSettingsCard(controller: widget.controller),
      'catalog-convergence' => CatalogConvergenceStatusCard(
        controller: widget.controller.catalogConvergenceController,
      ),
      'storage' => _StorageSettings(controller: widget.controller),
      'startup' => StartupAutostartCard(controller: widget.controller),
      _ => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsLogExportTile(controller: widget.controller),
          const SizedBox(height: LicoContentSpacing.item),
          const ClientResourceUsageCard(),
          const SizedBox(height: LicoContentSpacing.item),
          AgentResourceUsageCard(
            gateway: AgentResourceUsageGatewayAdapter(
              runner: widget.controller.agentService,
            ),
          ),
        ],
      ),
    };

    return [
      for (final descriptor in settingsSectionDescriptors(strings))
        _SettingsSection(
          id: descriptor.id,
          icon: descriptor.icon,
          label: descriptor.label,
          child: childFor(descriptor.id),
        ),
    ];
  }
}

class _SettingsSection {
  const _SettingsSection({
    required this.id,
    required this.icon,
    required this.label,
    required this.child,
  });

  final String id;
  final IconData icon;
  final String label;
  final Widget child;
}

class _SettingsIndexSidebar extends StatefulWidget {
  const _SettingsIndexSidebar({
    required this.width,
    required this.sections,
    required this.selectedId,
    required this.onSelect,
    required this.presentation,
  });

  final double width;
  final List<_SettingsSection> sections;
  final String selectedId;
  final ValueChanged<String> onSelect;
  final LayoutSettingsPresentation presentation;

  @override
  State<_SettingsIndexSidebar> createState() => _SettingsIndexSidebarState();
}

class _SettingsIndexSidebarState extends State<_SettingsIndexSidebar> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: SizedBox(
        width: widget.width,
        child: widget.presentation.frameIndex(
          context,
          hovered: _hovered,
          child: SafeArea(
            child: Padding(
              padding: widget.presentation.indexPadding,
              child: ListView(
                key: const Key('settings-index-scroll'),
                padding: EdgeInsets.zero,
                children: [
                  for (final section in widget.sections)
                    _IndexItem(
                      icon: section.icon,
                      label: section.label,
                      selected: widget.selectedId == section.id,
                      onTap: () => widget.onSelect(section.id),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _IndexItem extends StatefulWidget {
  const _IndexItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_IndexItem> createState() => _IndexItemState();
}

class _IndexItemState extends State<_IndexItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    // Solid brand-yellow selection with dark foreground, replacing the old
    // gold tint (primaryFixed background + primaryStrong text).
    final bgColor = widget.selected
        ? colors.primary
        : _hovered
        ? colors.surfaceLow.withAlpha(colors.isDark ? 120 : 80)
        : Colors.transparent;
    final fgColor = widget.selected ? colors.textOnPrimary : colors.text;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(
            horizontal: LicoContentSpacing.compact,
            vertical: LicoContentSpacing.inline / 2,
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: LicoContentSpacing.compact,
            vertical: LicoContentSpacing.compact,
          ),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Row(
            children: [
              Icon(widget.icon, size: 17, color: fgColor),
              const SizedBox(width: LicoContentSpacing.compact),
              Expanded(
                child: Text(
                  widget.label,
                  style: TextStyle(
                    color: fgColor,
                    fontSize: 12.5,
                    fontWeight: widget.selected
                        ? FontWeight.w700
                        : FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AppearanceSettings extends StatelessWidget {
  const _AppearanceSettings({
    required this.controller,
    required this.colors,
    required this.strings,
    required this.surface,
  });

  final ClientController controller;
  final LicoThemeColors colors;
  final LicoStrings strings;
  final LayoutRuntimeSurface surface;

  @override
  Widget build(BuildContext context) {
    final isDark = isResolvedAppearanceDark(
      controller.appearancePresetId,
      controller.appearancePresetConfigs,
      MediaQuery.platformBrightnessOf(context),
    );
    final selectablePresets = selectableAppearancePresetsForBrightness(
      controller.appearancePresetConfigs,
      isDark,
    );
    final selectedPresetId =
        selectablePresets.any(
          (config) => config.id == controller.appearancePresetId,
        )
        ? controller.appearancePresetId
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SettingsSectionHeader(
          title: strings.appearance,
          icon: Icons.palette_outlined,
          colors: colors,
        ),
        SettingsDropdownRow<String>(
          icon: Icons.language_outlined,
          title: strings.language,
          value: LocalePreference.normalize(controller.localePreference),
          items: LocalePreference.values
              .map(
                (value) => DropdownMenuItem(
                  value: value,
                  child: Text(strings.localePreferenceLabel(value)),
                ),
              )
              .toList(),
          onChanged: (value) {
            if (value != null) {
              unawaited(controller.setLocalePreference(value));
            }
          },
        ),
        SettingsDayNightToggleRow(
          selection: appearanceBrightnessSelectionFor(
            controller.appearancePresetId,
            controller.appearancePresetConfigs,
          ),
          disabledSegments: const {
            AppearanceBrightnessSelection.system,
            AppearanceBrightnessSelection.light,
          },
          onChanged: (selection) {
            unawaited(
              controller.setAppearancePreset(
                appearancePresetIdForBrightnessSelection(
                  selection,
                  controller.appearancePresetId,
                  controller.appearancePresetConfigs,
                ),
              ),
            );
          },
        ),
        SettingsDropdownRow<String>(
          icon: Icons.palette_outlined,
          title: strings.appearancePreset,
          value: selectedPresetId,
          items: selectablePresets
              .map(
                (config) => DropdownMenuItem(
                  value: config.id,
                  child: Text(
                    config.labelFor(strings.isChinese ? 'zh-CN' : 'en'),
                  ),
                ),
              )
              .toList(),
          onChanged: (presetId) {
            if (presetId != null) {
              unawaited(controller.setAppearancePreset(presetId));
            }
          },
        ),
        LayoutProfileSelector(
          manager: controller.layoutManager,
          registry: controller.layoutComposition.registry,
          surface: surface,
        ),
        DirectoryPathField(
          title: strings.appearancePresetDirectory,
          label: strings.appearancePresetDirectory,
          path: controller.appearancePresetDirectoryPath,
          icon: Icons.folder_copy_outlined,
          readOnly: true,
          onOpen: (path) => controller.openDirectoryPath(
            path,
            caption: strings.appearancePresetDirectory,
          ),
          headerTrailing: IconButton(
            tooltip: strings.reloadPresets,
            onPressed: () {
              unawaited(controller.reloadAppearancePresets());
            },
            icon: const Icon(Icons.refresh_outlined, size: 18),
          ),
        ),
        if (controller.appearancePresetLoadErrors.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              LicoContentSpacing.item,
              0,
              LicoContentSpacing.item,
              LicoContentSpacing.item,
            ),
            child: Text(
              strings.invalidPresetConfigs(
                controller.appearancePresetLoadErrors.length,
              ),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
      ],
    );
  }
}

class _StorageSettings extends StatelessWidget {
  const _StorageSettings({required this.controller});

  final ClientController controller;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SettingsSectionHeader(
          title: strings.storageAndData,
          icon: Icons.inventory_2_outlined,
          colors: context.licoColors,
        ),
        DirectoryPathField(
          title: strings.portableData,
          label: strings.portableData,
          path: controller.portableDataPath,
          icon: Icons.folder_outlined,
          readOnly: true,
          onOpen: (path) =>
              controller.openDirectoryPath(path, caption: strings.portableData),
        ),
        DirectoryPathField(
          title: strings.conversationArchiveRoot,
          label: strings.snapshotRootPath,
          controller: controller.snapshotRootController,
          icon: Icons.inventory_2_outlined,
          enabled: !controller.isSavingSnapshotRoot,
          busy: controller.isSavingSnapshotRoot,
          onOpen: (path) => controller.openDirectoryPath(
            path,
            caption: strings.conversationArchiveRoot,
          ),
          headerTrailing: IconButton(
            tooltip: strings.refreshArchiveRoot,
            onPressed: () {
              unawaited(controller.refreshConversationSnapshotRoot());
            },
            icon: const Icon(Icons.refresh_outlined, size: 18),
          ),
          actions: [
            SizedBox(
              height: 38,
              child: FilledButton.icon(
                onPressed: controller.isSavingSnapshotRoot
                    ? null
                    : () {
                        unawaited(
                          controller.setConversationSnapshotRoot(
                            controller.snapshotRootController.text,
                          ),
                        );
                      },
                icon: controller.isSavingSnapshotRoot
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined, size: 15),
                label: Text(strings.save),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _MobileSettingsBody extends StatelessWidget {
  const _MobileSettingsBody({
    required this.controller,
    required this.scrollController,
  });

  final ClientController controller;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    final isDark = isResolvedAppearanceDark(
      controller.appearancePresetId,
      controller.appearancePresetConfigs,
      MediaQuery.platformBrightnessOf(context),
    );
    final selectablePresets = selectableAppearancePresetsForBrightness(
      controller.appearancePresetConfigs,
      isDark,
    );
    final selectedPresetId =
        selectablePresets.any(
          (config) => config.id == controller.appearancePresetId,
        )
        ? controller.appearancePresetId
        : null;

    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.symmetric(vertical: LicoContentSpacing.item),
      children: [
        _SettingsSectionHeader(
          title: strings.appearance,
          icon: Icons.palette_outlined,
          colors: colors,
        ),
        SettingsDropdownRow<String>(
          icon: Icons.language_outlined,
          title: strings.language,
          value: LocalePreference.normalize(controller.localePreference),
          items: LocalePreference.values
              .map(
                (value) => DropdownMenuItem(
                  value: value,
                  child: Text(strings.localePreferenceLabel(value)),
                ),
              )
              .toList(),
          onChanged: (value) {
            if (value != null) {
              unawaited(controller.setLocalePreference(value));
            }
          },
        ),
        SettingsDayNightToggleRow(
          selection: appearanceBrightnessSelectionFor(
            controller.appearancePresetId,
            controller.appearancePresetConfigs,
          ),
          disabledSegments: const {
            AppearanceBrightnessSelection.system,
            AppearanceBrightnessSelection.light,
          },
          onChanged: (selection) {
            unawaited(
              controller.setAppearancePreset(
                appearancePresetIdForBrightnessSelection(
                  selection,
                  controller.appearancePresetId,
                  controller.appearancePresetConfigs,
                ),
              ),
            );
          },
        ),
        SettingsDropdownRow<String>(
          icon: Icons.palette_outlined,
          title: strings.appearancePreset,
          value: selectedPresetId,
          items: selectablePresets
              .map(
                (config) => DropdownMenuItem(
                  value: config.id,
                  child: Text(
                    config.labelFor(strings.isChinese ? 'zh-CN' : 'en'),
                  ),
                ),
              )
              .toList(),
          onChanged: (presetId) {
            if (presetId != null) {
              unawaited(controller.setAppearancePreset(presetId));
            }
          },
        ),
        LayoutProfileSelector(
          manager: controller.layoutManager,
          registry: controller.layoutComposition.registry,
          surface: LayoutRuntimeSurface.mobile,
        ),
      ],
    );
  }
}

class _SettingsSectionHeader extends StatelessWidget {
  const _SettingsSectionHeader({
    required this.title,
    required this.icon,
    required this.colors,
  });

  final String title;
  final IconData icon;
  final LicoThemeColors colors;

  @override
  Widget build(BuildContext context) {
    final presentation = LayoutDestinationPresentationScope.settingsOf(context);
    return Padding(
      padding: presentation.sectionHeaderPadding,
      child: Row(
        children: [
          Icon(icon, size: 18, color: colors.textSecondary),
          const SizedBox(width: LicoContentSpacing.compact),
          Expanded(
            child: Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}
