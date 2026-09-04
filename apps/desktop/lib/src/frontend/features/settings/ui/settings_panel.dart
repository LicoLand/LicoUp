import 'dart:async';

import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/contracts/locale_preferences.dart';
import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_state_port.dart';
import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/frontend/binding/projection_builder.dart';
import 'package:licoup/src/frontend/features/settings/ui/archived_conversations_settings_section.dart';
import 'package:licoup/src/frontend/features/settings/ui/client_update_settings_card.dart';
import 'package:licoup/src/frontend/features/settings/ui/layout_profile_selector.dart';
import 'package:licoup/src/frontend/features/settings/ui/catalog_convergence_status_card.dart';
import 'package:licoup/src/frontend/features/settings/ui/diagnostics_resource_section.dart';
import 'package:licoup/src/frontend/features/settings/ui/settings_log_export_tile.dart';
import 'package:licoup/src/frontend/features/settings/ui/settings_panel_widgets.dart';
import 'package:licoup/src/frontend/shared/settings_section_catalog.dart';
import 'package:licoup/src/frontend/features/settings/ui/startup_autostart_card.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_pane/resize.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/layout/layout_registry.dart';
import 'package:licoup/src/frontend/layout/layout_scope.dart';
import 'package:licoup/src/frontend/shared/platform/client_platform.dart';
import 'package:licoup/src/frontend/shared/ui/directory_path_field.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/lico_section_header.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/presentation/settings/settings_binding.dart';
import 'package:licoup/src/presentation/settings/settings_intent.dart';
import 'package:licoup/src/presentation/settings/settings_projection.dart';

const _settingsSectionIds = settingsSectionIdOrder;

/// Settings index rail bounds. The rail defaults to the narrowest usable
/// width and the user drags the split divider wider, mirroring the
/// conversation-list sidebar in the agents workspace.
const double _settingsIndexMinWidth = 120;
const double _settingsIndexMaxWidth = 360;
const double _settingsIndexDividerWidth = 8;
const double _settingsMinContentWidth = 360;

class SettingsPanel extends StatefulWidget {
  const SettingsPanel({
    super.key,
    required this.binding,
    required this.layoutRegistry,
  });

  final SettingsBinding binding;
  final LayoutRegistry layoutRegistry;

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
  StreamSubscription<void>? _layoutStateChanges;
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
    _layoutStateChanges = scope.state.changes.listen((_) {
      _syncSelectionFromStore();
    });

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
    if (_jumpInFlight ||
        _settling ||
        DateTime.now().isBefore(_settleSuppressedUntil)) {
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

  /// Jumps to a section even when the lazy list builder has disposed it.
  ///
  /// Travel by sub-viewport steps until the target is mounted, then settle
  /// exactly onto it. Jumping straight to an edge can skip an intermediate
  /// section entirely and leave the navigation selection at the wrong end.
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
    final targetIndex = _settingsSectionIds.indexOf(id);
    if (targetIndex < 0) return;
    while (mounted && _scrollController.hasClients) {
      final context = _keyFor(id).currentContext;
      if (context != null && context.mounted) {
        await Scrollable.ensureVisible(
          context,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutQuart,
          alignment: 0.02,
        );
        return;
      }
      final known = _sectionOffsets();
      if (known.isEmpty) return;
      final firstKnownIndex = _settingsSectionIds.indexOf(known.first.$1);
      final lastKnownIndex = _settingsSectionIds.indexOf(known.last.$1);
      final direction = targetIndex < firstKnownIndex
          ? -1.0
          : targetIndex > lastKnownIndex
          ? 1.0
          : 0.0;
      if (direction == 0) return;
      final position = _scrollController.position;
      final step = position.viewportDimension * 0.72;
      if (step <= 0) return;
      final destination = (position.pixels + direction * step)
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();
      if ((destination - position.pixels).abs() <= 0.5) return;
      await _scrollController.animateTo(
        destination,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _unwatchLayoutState() {
    unawaited(_layoutStateChanges?.cancel());
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
    return ProjectionBuilder<SettingsProjection, SettingsProjection>(
      source: widget.binding.projection,
      select: _settingsIdentity,
      builder: _buildPanel,
    );
  }

  Widget _buildPanel(BuildContext context, SettingsProjection projection) {
    final mobileClient = isMobileClientPlatform(context);

    if (mobileClient) {
      return _MobileSettingsBody(
        binding: widget.binding,
        layoutRegistry: widget.layoutRegistry,
        projection: projection,
        scrollController: _scrollController,
      );
    }

    final sections = _buildSections(context, projection);
    final presentation = layoutSettingsPresentationOf(context);

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
              // Equal space above and below the hairline; section headers
              // and rows use the same vertical token so the gap stays even.
              return Divider(
                key: Key('settings-section-divider-${sections[index ~/ 2].id}'),
                height: LicoContentSpacing.item,
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

  List<_SettingsSection> _buildSections(
    BuildContext context,
    SettingsProjection projection,
  ) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;

    // Navigation identity (icon and label) comes from the shared section
    // catalog so the shell navigation and any in-page rail never drift.
    Widget childFor(String id) => switch (id) {
      'general' => _GeneralSettings(
        binding: widget.binding,
        projection: projection,
        colors: colors,
        strings: strings,
      ),
      'appearance' => _AppearanceSettings(
        binding: widget.binding,
        layoutRegistry: widget.layoutRegistry,
        projection: projection,
        colors: colors,
        strings: strings,
        surface: LayoutRuntimeSurface.desktop,
      ),
      'updates' => ClientUpdateSettingsCard(binding: widget.binding),
      'catalog-convergence' => CatalogConvergenceStatusCard(
        binding: widget.binding,
      ),
      'storage' => _StorageSettings(
        binding: widget.binding,
        projection: projection,
      ),
      'startup' => StartupAutostartCard(binding: widget.binding),
      'archived-conversations' => ArchivedConversationsSettingsSection(
        binding: widget.binding,
      ),
      _ => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsLogExportTile(
            binding: widget.binding,
            projection: projection,
          ),
          const SizedBox(height: LicoContentSpacing.item),
          DiagnosticsResourceSection(binding: widget.binding),
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

class _GeneralSettings extends StatelessWidget {
  const _GeneralSettings({
    required this.binding,
    required this.projection,
    required this.colors,
    required this.strings,
  });

  final SettingsBinding binding;
  final SettingsProjection projection;
  final LicoThemeColors colors;
  final LicoStrings strings;

  @override
  Widget build(BuildContext context) {
    final presentation = layoutSettingsPresentationOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LicoSectionHeader(
          title: strings.general,
          leading: Icon(
            Icons.tune_outlined,
            size: 18,
            color: colors.textSecondary,
          ),
          padding: presentation.sectionHeaderPadding,
        ),
        SettingsDropdownRow<String>(
          dropdownKey: const Key('settings-locale-dropdown'),
          icon: Icons.language_outlined,
          title: strings.language,
          value: _selectedChoiceId(projection.localeChoices),
          items: [
            for (final preference in LocalePreference.values)
              SettingsDropdownItem(
                value: preference,
                label: strings.localePreferenceLabel(preference),
                key: Key('settings-locale-$preference'),
              ),
          ],
          onSelected: (value) {
            binding.intents.send(SetLocalePreference(value));
          },
        ),
      ],
    );
  }
}

class _AppearanceSettings extends StatelessWidget {
  const _AppearanceSettings({
    required this.binding,
    required this.layoutRegistry,
    required this.projection,
    required this.colors,
    required this.strings,
    required this.surface,
  });

  final SettingsBinding binding;
  final LayoutRegistry layoutRegistry;
  final SettingsProjection projection;
  final LicoThemeColors colors;
  final LicoStrings strings;
  final LayoutRuntimeSurface surface;

  @override
  Widget build(BuildContext context) {
    final presentation = layoutSettingsPresentationOf(context);
    final configs = projection.appearancePresets;
    final currentId = projection.appearancePresetId;
    final isDark = _isResolvedAppearanceDark(
      currentId,
      configs,
      MediaQuery.platformBrightnessOf(context),
    );
    final selectablePresets = _selectableAppearancePresetsForBrightness(
      configs,
      isDark,
    );
    final selectedPresetId =
        selectablePresets.any((config) => config.id == currentId)
        ? currentId
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LicoSectionHeader(
          title: strings.appearance,
          leading: Icon(
            Icons.palette_outlined,
            size: 18,
            color: colors.textSecondary,
          ),
          padding: presentation.sectionHeaderPadding,
        ),
        SettingsDayNightToggleRow(
          selection: _appearanceBrightnessSelectionFor(currentId, configs),
          disabledSegments: const {
            AppearanceBrightnessSelection.system,
            AppearanceBrightnessSelection.light,
          },
          onChanged: (selection) {
            binding.intents.send(
              SetAppearancePreference(
                _appearancePresetIdForBrightnessSelection(
                  selection,
                  currentId,
                  configs,
                ),
              ),
            );
          },
        ),
        SettingsDropdownRow<String>(
          dropdownKey: const Key('settings-appearance-dropdown'),
          icon: Icons.palette_outlined,
          title: strings.appearancePreset,
          value: selectedPresetId,
          locked: true,
          items: [
            for (final config in selectablePresets)
              SettingsDropdownItem(
                value: config.id,
                label: config.labelFor(strings.isChinese),
              ),
          ],
          onSelected: (presetId) {
            binding.intents.send(SetAppearancePreference(presetId));
          },
        ),
        LayoutProfileSelector(
          binding: binding,
          registry: layoutRegistry,
          surface: surface,
        ),
        DirectoryPathField(
          title: strings.appearancePresetDirectory,
          label: strings.appearancePresetDirectory,
          path: projection.appearancePresetDirectoryPath,
          icon: Icons.folder_copy_outlined,
          readOnly: true,
          padding: presentation.rowPadding,
          onOpen: (_) {
            binding.intents.send(
              OpenSettingsDirectory(
                SettingsDirectory.appearancePresets,
                caption: strings.appearancePresetDirectory,
              ),
            );
            return Future<void>.value();
          },
          headerTrailing: IconButton(
            tooltip: strings.reloadPresets,
            onPressed: () {
              binding.intents.send(const ReloadAppearancePresets());
            },
            icon: const Icon(Icons.refresh_outlined, size: 18),
          ),
        ),
        if (projection.appearancePresetLoadErrorCount > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              LicoContentSpacing.item,
              0,
              LicoContentSpacing.item,
              LicoContentSpacing.item,
            ),
            child: Text(
              strings.invalidPresetConfigs(
                projection.appearancePresetLoadErrorCount,
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

class _StorageSettings extends StatefulWidget {
  const _StorageSettings({required this.binding, required this.projection});

  final SettingsBinding binding;
  final SettingsProjection projection;

  @override
  State<_StorageSettings> createState() => _StorageSettingsState();
}

class _StorageSettingsState extends State<_StorageSettings> {
  late final TextEditingController _snapshotRootController;
  late String _lastSnapshotRootPath;

  @override
  void initState() {
    super.initState();
    _lastSnapshotRootPath = widget.projection.snapshotRootPath;
    _snapshotRootController = TextEditingController(
      text: _lastSnapshotRootPath,
    );
  }

  @override
  void didUpdateWidget(_StorageSettings oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = widget.projection.snapshotRootPath;
    if (next != _lastSnapshotRootPath) {
      _lastSnapshotRootPath = next;
      _snapshotRootController.text = next;
    }
  }

  @override
  void dispose() {
    _snapshotRootController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final presentation = layoutSettingsPresentationOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LicoSectionHeader(
          title: strings.storageAndData,
          leading: Icon(
            Icons.inventory_2_outlined,
            size: 18,
            color: context.licoColors.textSecondary,
          ),
          padding: presentation.sectionHeaderPadding,
        ),
        DirectoryPathField(
          title: strings.portableData,
          label: strings.portableData,
          path: widget.projection.portableDataPath,
          icon: Icons.folder_outlined,
          readOnly: true,
          padding: presentation.rowPadding,
          onOpen: (_) {
            widget.binding.intents.send(
              OpenSettingsDirectory(
                SettingsDirectory.portableData,
                caption: strings.portableData,
              ),
            );
            return Future<void>.value();
          },
        ),
        DirectoryPathField(
          title: strings.conversationArchiveRoot,
          label: strings.snapshotRootPath,
          controller: _snapshotRootController,
          icon: Icons.inventory_2_outlined,
          padding: presentation.rowPadding,
          enabled: !widget.projection.savingSnapshotRoot,
          busy: widget.projection.savingSnapshotRoot,
          onOpen: (_) {
            widget.binding.intents.send(
              OpenSettingsDirectory(
                SettingsDirectory.conversationSnapshots,
                path: _snapshotRootController.text,
                caption: strings.conversationArchiveRoot,
              ),
            );
            return Future<void>.value();
          },
          headerTrailing: IconButton(
            tooltip: strings.refreshArchiveRoot,
            onPressed: () {
              widget.binding.intents.send(
                const RefreshConversationSnapshotLocation(),
              );
            },
            icon: const Icon(Icons.refresh_outlined, size: 18),
          ),
          actions: [
            SizedBox(
              height: 38,
              child: FilledButton.icon(
                onPressed: widget.projection.savingSnapshotRoot
                    ? null
                    : () {
                        widget.binding.intents.send(
                          SetConversationSnapshotLocation(
                            _snapshotRootController.text,
                          ),
                        );
                      },
                icon: widget.projection.savingSnapshotRoot
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
    required this.binding,
    required this.layoutRegistry,
    required this.projection,
    required this.scrollController,
  });

  final SettingsBinding binding;
  final LayoutRegistry layoutRegistry;
  final SettingsProjection projection;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    final presentation = layoutSettingsPresentationOf(context);
    final currentId = projection.appearancePresetId;
    final configs = projection.appearancePresets;
    final isDark = _isResolvedAppearanceDark(
      currentId,
      configs,
      MediaQuery.platformBrightnessOf(context),
    );
    final selectablePresets = _selectableAppearancePresetsForBrightness(
      configs,
      isDark,
    );
    final selectedPresetId =
        selectablePresets.any((config) => config.id == currentId)
        ? currentId
        : null;

    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.symmetric(vertical: LicoContentSpacing.item),
      children: [
        LicoSectionHeader(
          title: strings.general,
          leading: Icon(
            Icons.tune_outlined,
            size: 18,
            color: colors.textSecondary,
          ),
          padding: presentation.sectionHeaderPadding,
        ),
        SettingsDropdownRow<String>(
          dropdownKey: const Key('settings-locale-dropdown'),
          icon: Icons.language_outlined,
          title: strings.language,
          value: _selectedChoiceId(projection.localeChoices),
          items: [
            for (final preference in LocalePreference.values)
              SettingsDropdownItem(
                value: preference,
                label: strings.localePreferenceLabel(preference),
                key: Key('settings-locale-$preference'),
              ),
          ],
          onSelected: (value) {
            binding.intents.send(SetLocalePreference(value));
          },
        ),
        LicoSectionHeader(
          title: strings.appearance,
          leading: Icon(
            Icons.palette_outlined,
            size: 18,
            color: colors.textSecondary,
          ),
          padding: presentation.sectionHeaderPadding,
        ),
        SettingsDayNightToggleRow(
          selection: _appearanceBrightnessSelectionFor(currentId, configs),
          disabledSegments: const {
            AppearanceBrightnessSelection.system,
            AppearanceBrightnessSelection.light,
          },
          onChanged: (selection) {
            binding.intents.send(
              SetAppearancePreference(
                _appearancePresetIdForBrightnessSelection(
                  selection,
                  currentId,
                  configs,
                ),
              ),
            );
          },
        ),
        SettingsDropdownRow<String>(
          dropdownKey: const Key('settings-appearance-dropdown'),
          icon: Icons.palette_outlined,
          title: strings.appearancePreset,
          value: selectedPresetId,
          locked: true,
          items: [
            for (final config in selectablePresets)
              SettingsDropdownItem(
                value: config.id,
                label: config.labelFor(strings.isChinese),
              ),
          ],
          onSelected: (presetId) {
            binding.intents.send(SetAppearancePreference(presetId));
          },
        ),
        LayoutProfileSelector(
          binding: binding,
          registry: layoutRegistry,
          surface: LayoutRuntimeSurface.mobile,
        ),
      ],
    );
  }
}

String? _selectedChoiceId(List<PresentationChoice> choices) {
  for (final choice in choices) {
    if (choice.selected) return choice.id;
  }
  return null;
}

SettingsProjection _settingsIdentity(SettingsProjection value) => value;

SettingsAppearancePresetProjection _appearancePreset(
  String id,
  List<SettingsAppearancePresetProjection> presets,
) {
  for (final preset in presets) {
    if (preset.id == id) return preset;
  }
  return presets.first;
}

bool _isResolvedAppearanceDark(
  String selectedId,
  List<SettingsAppearancePresetProjection> presets,
  Brightness platformBrightness,
) {
  final selected = _appearancePreset(selectedId, presets);
  return switch (selected.mode) {
    SettingsAppearanceMode.dark => true,
    SettingsAppearanceMode.light => false,
    SettingsAppearanceMode.system => platformBrightness == Brightness.dark,
  };
}

AppearanceBrightnessSelection _appearanceBrightnessSelectionFor(
  String selectedId,
  List<SettingsAppearancePresetProjection> presets,
) => switch (_appearancePreset(selectedId, presets).mode) {
  SettingsAppearanceMode.system => AppearanceBrightnessSelection.system,
  SettingsAppearanceMode.light => AppearanceBrightnessSelection.light,
  SettingsAppearanceMode.dark => AppearanceBrightnessSelection.dark,
};

String _appearancePresetIdForBrightnessSelection(
  AppearanceBrightnessSelection selection,
  String currentId,
  List<SettingsAppearancePresetProjection> presets,
) => switch (selection) {
  AppearanceBrightnessSelection.system => AppearancePresetIds.defaultSystem,
  AppearanceBrightnessSelection.light =>
    _appearancePreset(currentId, presets).mode == SettingsAppearanceMode.light
        ? currentId
        : AppearancePresetIds.licoSodaLight,
  AppearanceBrightnessSelection.dark =>
    _appearancePreset(currentId, presets).mode == SettingsAppearanceMode.dark
        ? currentId
        : AppearancePresetIds.licoSoda,
};

List<SettingsAppearancePresetProjection>
_selectableAppearancePresetsForBrightness(
  List<SettingsAppearancePresetProjection> presets,
  bool dark,
) => presets
    .where(
      (preset) =>
          !AppearancePresetIds.resolutionOnly.contains(preset.id) &&
          preset.mode != SettingsAppearanceMode.system &&
          (dark
              ? preset.mode == SettingsAppearanceMode.dark
              : preset.mode == SettingsAppearanceMode.light),
    )
    .toList(growable: false);
