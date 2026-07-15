import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/application/features/layout/layout_state_store.dart';
import 'package:flutter_client/src/contracts/locale_preferences.dart';
import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/target_candidate.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/contracts/presentation/layout_state_namespace.dart';
import 'package:flutter_client/src/frontend/features/settings/ui/layout_profile_selector.dart';
import 'package:flutter_client/src/frontend/features/settings/ui/local_runtime_settings_card.dart';
import 'package:flutter_client/src/frontend/features/settings/ui/client_update_settings_card.dart';
import 'package:flutter_client/src/frontend/features/settings/ui/proxy_bridge_settings.dart';
import 'package:flutter_client/src/frontend/features/settings/ui/settings_log_export_tile.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/layout/layout_destination_presentation.dart';
import 'package:flutter_client/src/frontend/layout/layout_scope.dart';
import 'package:flutter_client/src/frontend/shared/platform/client_platform.dart';
import 'package:flutter_client/src/frontend/shared/ui/directory_path_field.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

part 'settings_panel_widgets.dart';

const _settingsSectionIds = <String>[
  'appearance',
  'agent',
  'network',
  'runtime',
  'updates',
  'storage',
  'diagnostics',
];

class SettingsPanel extends StatefulWidget {
  const SettingsPanel({super.key, required this.controller});

  final ClientController controller;

  @override
  State<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<SettingsPanel> {
  final _scrollController = ScrollController();
  final _sectionKeys = <String, GlobalKey>{};
  String? _selectedSectionId;
  LayoutScopedState? _layoutState;
  String? _layoutStateIdentity;
  double? _pendingScrollOffset;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_persistScrollOffset);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = LayoutScope.maybeOf(context);
    if (scope == null) {
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
    _layoutStateIdentity = identity;
    _layoutState = scope.state;

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

  GlobalKey _keyFor(String id) {
    return _sectionKeys.putIfAbsent(id, GlobalKey.new);
  }

  void _scrollTo(String id) {
    final context = _keyFor(id).currentContext;
    if (context == null) {
      return;
    }
    setState(() => _selectedSectionId = id);
    final index = _settingsSectionIds.indexOf(id);
    if (index >= 0) {
      _layoutState?.writeIfDeclared(
        LayoutStateChannels.settingsSection,
        LayoutTabState(index),
      );
    }
    Scrollable.ensureVisible(
      context,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutQuart,
      alignment: 0.02,
    );
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_persistScrollOffset)
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

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SettingsIndexSidebar(
          sections: sections,
          selectedId: _selectedSectionId ?? sections.first.id,
          onSelect: _scrollTo,
          presentation: presentation,
        ),
        Expanded(
          child: Scrollbar(
            controller: _scrollController,
            child: ListView.builder(
              controller: _scrollController,
              padding: presentation.contentPadding,
              itemCount: sections.length,
              itemBuilder: (context, index) {
                final section = sections[index];
                return presentation.frameSection(
                  context,
                  key: _keyFor(section.id),
                  child: section.child,
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  List<_SettingsSection> _buildSections(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    final selectedPresetId =
        widget.controller.appearancePresetConfigs.any(
          (config) => config.id == widget.controller.appearancePresetId,
        )
        ? widget.controller.appearancePresetId
        : null;

    return [
      _SettingsSection(
        id: 'appearance',
        icon: Icons.palette_outlined,
        label: strings.appearance,
        child: _AppearanceSettings(
          controller: widget.controller,
          colors: colors,
          selectedPresetId: selectedPresetId,
          strings: strings,
          surface: LayoutRuntimeSurface.desktop,
        ),
      ),
      _SettingsSection(
        id: 'agent',
        icon: Icons.support_agent_outlined,
        label: strings.agentConfiguration,
        child: _AssistantAgentSettings(controller: widget.controller),
      ),
      _SettingsSection(
        id: 'network',
        icon: Icons.hub_outlined,
        label: strings.network,
        child: ProxyBridgeSettings(controller: widget.controller),
      ),
      _SettingsSection(
        id: 'runtime',
        icon: Icons.dns_outlined,
        label: strings.runtime,
        child: LocalRuntimeSettingsCard(
          controller: widget.controller,
          onOpenDetails: () =>
              widget.controller.selectSection(ClientSection.localRuntime),
        ),
      ),
      _SettingsSection(
        id: 'updates',
        icon: Icons.system_update_alt,
        label: strings.clientUpdate,
        child: ClientUpdateSettingsCard(controller: widget.controller),
      ),
      _SettingsSection(
        id: 'storage',
        icon: Icons.inventory_2_outlined,
        label: strings.storageAndData,
        child: _StorageSettings(controller: widget.controller),
      ),
      _SettingsSection(
        id: 'diagnostics',
        icon: Icons.bug_report_outlined,
        label: strings.diagnostics,
        child: SettingsLogExportTile(controller: widget.controller),
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
    required this.sections,
    required this.selectedId,
    required this.onSelect,
    required this.presentation,
  });

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
        width: 180,
        child: widget.presentation.frameIndex(
          context,
          hovered: _hovered,
          child: SafeArea(
            child: Padding(
              padding: widget.presentation.indexPadding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
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
    final bgColor = widget.selected
        ? colors.primaryFixed
        : _hovered
        ? colors.surfaceLow.withAlpha(colors.isDark ? 120 : 80)
        : Colors.transparent;
    final fgColor = widget.selected ? colors.primaryStrong : colors.text;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Row(
            children: [
              Icon(widget.icon, size: 17, color: fgColor),
              const SizedBox(width: 9),
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
    required this.selectedPresetId,
    required this.strings,
    required this.surface,
  });

  final ClientController controller;
  final LicoThemeColors colors;
  final String? selectedPresetId;
  final LicoStrings strings;
  final LayoutRuntimeSurface surface;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SettingsSectionHeader(
          title: strings.appearance,
          icon: Icons.palette_outlined,
          colors: colors,
        ),
        _SettingsDropdownRow<String>(
          icon: Icons.palette_outlined,
          title: strings.appearancePreset,
          value: selectedPresetId,
          items: controller.appearancePresetConfigs
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
        _SettingsDropdownRow<String>(
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
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
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
    final selectedPresetId =
        controller.appearancePresetConfigs.any(
          (config) => config.id == controller.appearancePresetId,
        )
        ? controller.appearancePresetId
        : null;

    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        _SettingsSectionHeader(
          title: strings.appearance,
          icon: Icons.palette_outlined,
          colors: colors,
        ),
        _SettingsDropdownRow<String>(
          icon: Icons.palette_outlined,
          title: strings.appearancePreset,
          value: selectedPresetId,
          items: controller.appearancePresetConfigs
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
        _SettingsDropdownRow<String>(
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
          Icon(icon, size: 18, color: colors.primary),
          const SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: colors.text,
              letterSpacing: -0.2,
            ),
          ),
        ],
      ),
    );
  }
}

InputDecoration _dropdownDecorationWithoutLabel() {
  return const InputDecoration(
    floatingLabelBehavior: FloatingLabelBehavior.never,
  );
}
