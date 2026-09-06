import 'dart:async';

import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/dashboard_feature_order.dart';
import 'package:licoup/src/frontend/layout/layout_state_port.dart';
import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/shared/client_platform_ports.dart';
import 'package:licoup/src/frontend/shared/dashboard_feature_order_store.dart';
import 'package:licoup/src/frontend/shared/settings_section_catalog.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_port.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/layout_scope.dart';
import 'package:licoup/src/frontend/layout/layout_value_builder.dart';
import 'package:licoup/src/frontend/shared/messaging/messaging_sidebar_foundation.dart';
import 'package:licoup/src/frontend/shared/ui/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';

/// Telegram-style tabs at the bottom of the shared sidebar foundation.
enum MessagingSidebarNavItem { features, conversations, settings }

/// One row of the Dashboard 功能 list. 模型网关 and 聊天频道 both target the
/// models destination and differ only in the pane they select through the
/// retained communicationSection channel.
enum MessagingFeatureItem {
  agentHub,
  modelGateway,
  mobilePairing,
  statsPanel,
  pluginManagement,
  skillHub,
  chatChannels,
}

const messagingCommunicationModelsPaneGateway = 0;
const messagingCommunicationModelsPaneChatChannels = 1;

/// One unified sidebar chrome: the search capsule stays pinned on top while
/// switching between any destinations — the shell never swaps sidebar chrome
/// per option.
bool messagingSidebarShowsSearch(ClientSection section) => true;

/// Destinations the 功能 bottom-nav tab owns: the seven sidebar-hosted
/// feature panes, 统计面板 included.
bool messagingSidebarHostsFeatures(ClientSection section) =>
    section == ClientSection.agentHub ||
    section == ClientSection.models ||
    section == ClientSection.mobileRelay ||
    section == ClientSection.monitoring ||
    section == ClientSection.pluginManagement ||
    section == ClientSection.skillHub;

ClientSection messagingSidebarNavTarget({
  required MessagingSidebarNavItem item,
  required ClientSection current,
}) => switch (item) {
  MessagingSidebarNavItem.features =>
    messagingSidebarHostsFeatures(current) ? current : ClientSection.agentHub,
  MessagingSidebarNavItem.conversations => ClientSection.agents,
  MessagingSidebarNavItem.settings => ClientSection.settings,
};

bool messagingSidebarNavItemSelected({
  required MessagingSidebarNavItem item,
  required ClientSection current,
}) => switch (item) {
  MessagingSidebarNavItem.features => messagingSidebarHostsFeatures(current),
  MessagingSidebarNavItem.conversations => current == ClientSection.agents,
  MessagingSidebarNavItem.settings => current == ClientSection.settings,
};

IconData messagingSidebarNavIcon(MessagingSidebarNavItem item) =>
    switch (item) {
      MessagingSidebarNavItem.features => Icons.functions,
      MessagingSidebarNavItem.conversations =>
        Icons.chat_bubble_outline_rounded,
      MessagingSidebarNavItem.settings => Icons.settings_outlined,
    };

String messagingSidebarNavLabel(
  LicoStrings strings,
  MessagingSidebarNavItem item,
) => switch (item) {
  MessagingSidebarNavItem.features => strings.features,
  MessagingSidebarNavItem.conversations => strings.conversationListNav,
  MessagingSidebarNavItem.settings => strings.settings,
};

String messagingSidebarNavKey(MessagingSidebarNavItem item) =>
    'messaging-sidebar-nav-${item.name}';

String messagingFeatureItemLabel(
  LicoStrings strings,
  MessagingFeatureItem item,
) => switch (item) {
  MessagingFeatureItem.agentHub => strings.agentHub,
  MessagingFeatureItem.modelGateway => strings.modelGateway,
  MessagingFeatureItem.mobilePairing => strings.mobilePairing,
  MessagingFeatureItem.statsPanel => strings.statsPanel,
  MessagingFeatureItem.pluginManagement => strings.pluginManagement,
  MessagingFeatureItem.skillHub => strings.skillHubNav,
  MessagingFeatureItem.chatChannels => strings.chatChannels,
};

IconData messagingFeatureItemIcon(MessagingFeatureItem item) => switch (item) {
  MessagingFeatureItem.agentHub => Icons.auto_awesome_outlined,
  MessagingFeatureItem.modelGateway => Icons.key_outlined,
  MessagingFeatureItem.mobilePairing => Icons.qr_code_2_rounded,
  MessagingFeatureItem.statsPanel => Icons.query_stats_outlined,
  MessagingFeatureItem.pluginManagement => Icons.extension_outlined,
  MessagingFeatureItem.skillHub => Icons.library_books_outlined,
  MessagingFeatureItem.chatChannels => Icons.forum_outlined,
};

ClientSection messagingFeatureItemSection(MessagingFeatureItem item) =>
    switch (item) {
      MessagingFeatureItem.agentHub => ClientSection.agentHub,
      MessagingFeatureItem.modelGateway => ClientSection.models,
      MessagingFeatureItem.mobilePairing => ClientSection.mobileRelay,
      MessagingFeatureItem.statsPanel => ClientSection.monitoring,
      MessagingFeatureItem.pluginManagement => ClientSection.pluginManagement,
      MessagingFeatureItem.skillHub => ClientSection.skillHub,
      MessagingFeatureItem.chatChannels => ClientSection.models,
    };

/// The models pane a 功能 entry selects, or null for non-models entries.
int? messagingFeatureItemModelsPane(MessagingFeatureItem item) =>
    switch (item) {
      MessagingFeatureItem.modelGateway =>
        messagingCommunicationModelsPaneGateway,
      MessagingFeatureItem.chatChannels =>
        messagingCommunicationModelsPaneChatChannels,
      _ => null,
    };

int messagingCommunicationModelsPaneIndex(LayoutScopedState? state) {
  final tab = state?.readIfDeclaredFor(
    ClientSection.models,
    LayoutStateChannels.communicationSection,
  );
  if (tab is LayoutTabState &&
      tab.index == messagingCommunicationModelsPaneChatChannels) {
    return messagingCommunicationModelsPaneChatChannels;
  }
  return messagingCommunicationModelsPaneGateway;
}

bool messagingFeatureItemSelected({
  required MessagingFeatureItem item,
  required ClientSection current,
  required int modelsPane,
}) {
  final section = messagingFeatureItemSection(item);
  if (section == ClientSection.models) {
    return current == ClientSection.models &&
        messagingFeatureItemModelsPane(item) == modelsPane;
  }
  return current == section;
}

IconData messagingSidebarDestinationIcon(ClientSection section) =>
    switch (section) {
      ClientSection.agents => Icons.chat_bubble_outline_rounded,
      ClientSection.skillHub => Icons.library_books_outlined,
      ClientSection.pluginManagement => Icons.extension_outlined,
      ClientSection.agentHub => Icons.auto_awesome_outlined,
      ClientSection.monitoring => Icons.query_stats_outlined,
      ClientSection.models => Icons.key_outlined,
      ClientSection.mobileRelay => Icons.qr_code_2_rounded,
      ClientSection.settings => Icons.settings_outlined,
    };

int messagingSettingsSectionIndex(LayoutScopedState? state) {
  final tab = state?.readIfDeclared(LayoutStateChannels.settingsSection);
  if (tab is LayoutTabState && tab.index < settingsSectionIdOrder.length) {
    return tab.index;
  }
  return 0;
}

Widget messagingSidebarListFor({
  required ClientSection destination,
  required ValueChanged<ClientSection> onSelectDestination,
  int settingsSectionIndex = 0,
  ValueChanged<int>? onSelectSettings,
}) {
  if (destination == ClientSection.settings) {
    return MessagingSettingsSectionList(
      selectedIndex: settingsSectionIndex,
      onSelectIndex: onSelectSettings ?? (_) {},
    );
  }
  if (messagingSidebarHostsFeatures(destination)) {
    return MessagingFeatureSidebarList(
      current: destination,
      onSelectDestination: onSelectDestination,
    );
  }
  return const SizedBox.expand();
}

/// Persistent bottom bar for the shared sidebar foundation.
final class MessagingSidebarBottomNav extends StatelessWidget {
  const MessagingSidebarBottomNav({
    super.key,
    required this.current,
    required this.onSelectDestination,
  });

  final ClientSection current;
  final ValueChanged<ClientSection> onSelectDestination;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    final strings = LicoStrings.of(context);
    return DecoratedBox(
      key: const Key('messaging-sidebar-bottom-nav'),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: colors.line,
            width: MessagingDesktopMetrics.hairline,
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(LicoContentSpacing.compact),
        child: Row(
          children: [
            for (final item in MessagingSidebarNavItem.values)
              Expanded(
                child: _MessagingSidebarNavButton(
                  key: Key(messagingSidebarNavKey(item)),
                  item: item,
                  label: messagingSidebarNavLabel(strings, item),
                  selected: messagingSidebarNavItemSelected(
                    item: item,
                    current: current,
                  ),
                  onPressed: () => onSelectDestination(
                    messagingSidebarNavTarget(item: item, current: current),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

final class _MessagingSidebarNavButton extends StatefulWidget {
  const _MessagingSidebarNavButton({
    super.key,
    required this.item,
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final MessagingSidebarNavItem item;
  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  State<_MessagingSidebarNavButton> createState() =>
      _MessagingSidebarNavButtonState();
}

final class _MessagingSidebarNavButtonState
    extends State<_MessagingSidebarNavButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    final selected = widget.selected;
    final foreground = selected
        ? colors.textOnPrimary
        : _hovered
        ? colors.text
        : colors.textMuted;
    return Semantics(
      button: true,
      selected: selected,
      label: widget.label,
      child: Tooltip(
        message: widget.label,
        waitDuration: LicoMotion.tooltipWait,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onPressed,
            child: AnimatedContainer(
              duration: LicoMotion.micro,
              curve: LicoMotion.standard,
              // 8.5 margins make the button exactly square at the default
              // sidebar width; wider columns stretch it wider than square.
              margin: const EdgeInsets.symmetric(
                horizontal:
                    MessagingDesktopMetrics.sidebarBottomNavButtonMargin,
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: LicoContentSpacing.inline,
                vertical: LicoContentSpacing.compact,
              ),
              decoration: BoxDecoration(
                color: selected
                    ? colors.primary
                    : _hovered
                    ? colors.hoverOverlay
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(LicoRadius.chip),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    messagingSidebarNavIcon(widget.item),
                    size: 20,
                    color: foreground,
                  ),
                  const SizedBox(height: LicoContentSpacing.inline),
                  Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: foreground,
                      fontSize: 10,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      height: 1.1,
                    ),
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

/// House-selection row shared by every dedicated sidebar index list.
final class MessagingSidebarIndexRow extends StatefulWidget {
  const MessagingSidebarIndexRow({
    super.key,
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
  State<MessagingSidebarIndexRow> createState() =>
      _MessagingSidebarIndexRowState();
}

final class _MessagingSidebarIndexRowState
    extends State<MessagingSidebarIndexRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    final selected = widget.selected;
    final foreground = selected ? colors.textOnPrimary : colors.text;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: LicoMotion.micro,
          curve: LicoMotion.standard,
          margin: const EdgeInsets.only(bottom: LicoContentSpacing.compact),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          decoration: BoxDecoration(
            color: selected
                ? colors.primary
                : _hovered
                ? colors.hoverOverlay
                : Colors.transparent,
            borderRadius: BorderRadius.circular(LicoRadius.chip),
          ),
          child: Row(
            children: [
              Icon(widget.icon, size: 20, color: foreground),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: foreground,
                    fontSize: 14,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
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

/// Canonical settings catalog rows hosted in the shared sidebar list slot.
final class MessagingSettingsSectionList extends StatelessWidget {
  const MessagingSettingsSectionList({
    super.key,
    required this.selectedIndex,
    required this.onSelectIndex,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelectIndex;

  @override
  Widget build(BuildContext context) {
    final sections = settingsSectionDescriptors(LicoStrings.of(context));
    return ListView.builder(
      key: const Key('messaging-sidebar-settings-list'),
      padding: const EdgeInsets.fromLTRB(
        LicoContentSpacing.compact,
        0,
        LicoContentSpacing.compact,
        LicoContentSpacing.item,
      ),
      itemCount: sections.length,
      itemBuilder: (context, index) {
        final section = sections[index];
        return MessagingSidebarIndexRow(
          key: Key('messaging-sidebar-settings-${section.id}'),
          icon: section.icon,
          label: section.label,
          selected: selectedIndex == index,
          onTap: () => onSelectIndex(index),
        );
      },
    );
  }
}

/// Optional ambient override of the 功能 order store and its storage root.
/// Production shells never provide it (the platform store and the real
/// client-state directory are used); tests provide an in-memory store so the
/// sidebar never touches the host's real `dashboard-feature-order.json`.
final class MessagingFeatureOrderScope extends InheritedWidget {
  const MessagingFeatureOrderScope({
    super.key,
    this.orderStore,
    this.portableData,
    required super.child,
  });

  final DashboardFeatureOrderStore? orderStore;
  final Object? portableData;

  static MessagingFeatureOrderScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MessagingFeatureOrderScope>();

  @override
  bool updateShouldNotify(MessagingFeatureOrderScope oldWidget) =>
      !identical(oldWidget.orderStore, orderStore) ||
      !identical(oldWidget.portableData, portableData);
}

/// The seven-entry 功能 list: 智能体中心, 模型网关, 移动配对, 统计面板, 插件管理,
/// 技能一览, 聊天频道 in the frozen default order. Long-press drag reorders
/// entries vertically and the custom order persists through
/// `dashboard-feature-order.json`.
final class MessagingFeatureSidebarList extends StatefulWidget {
  const MessagingFeatureSidebarList({
    super.key,
    required this.current,
    required this.onSelectDestination,
  });

  final ClientSection current;
  final ValueChanged<ClientSection> onSelectDestination;

  @override
  State<MessagingFeatureSidebarList> createState() =>
      _MessagingFeatureSidebarListState();
}

final class _MessagingFeatureSidebarListState
    extends State<MessagingFeatureSidebarList> {
  static const _defaultItems = <MessagingFeatureItem>[
    MessagingFeatureItem.agentHub,
    MessagingFeatureItem.modelGateway,
    MessagingFeatureItem.mobilePairing,
    MessagingFeatureItem.statsPanel,
    MessagingFeatureItem.pluginManagement,
    MessagingFeatureItem.skillHub,
    MessagingFeatureItem.chatChannels,
  ];

  late List<MessagingFeatureItem> _order = _itemsFor(
    DashboardFeatureOrder.defaultOrder,
  );
  late DashboardFeatureOrderStore _orderStore;
  late Object _portableData;
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = MessagingFeatureOrderScope.maybeOf(context);
    _orderStore = scope?.orderStore ?? ClientPlatformPorts.featureOrderStore();
    _portableData =
        scope?.portableData ??
        ClientPlatformPorts.portableData ??
        const Object();
    if (!_loaded) {
      _loaded = true;
      _order = _itemsFor(
        DashboardFeatureOrderStore.lastKnownOrder ??
            DashboardFeatureOrder.defaultOrder,
      );
      unawaited(_load());
    }
  }

  List<MessagingFeatureItem> _itemsFor(List<String> ids) {
    final byName = <String, MessagingFeatureItem>{
      for (final item in MessagingFeatureItem.values) item.name: item,
    };
    final ordered = <MessagingFeatureItem>[];
    for (final id in ids) {
      final item = byName[id];
      if (item != null && !ordered.contains(item)) {
        ordered.add(item);
      }
    }
    for (final item in _defaultItems) {
      if (!ordered.contains(item)) {
        ordered.add(item);
      }
    }
    return List.unmodifiable(ordered);
  }

  Future<void> _load() async {
    List<String> ids;
    try {
      ids = await _orderStore.load(_portableData);
    } on Object {
      // A corrupt durable document never breaks the sidebar; keep the
      // default order already on screen.
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() => _order = _itemsFor(ids));
  }

  void _select(MessagingFeatureItem item) {
    final pane = messagingFeatureItemModelsPane(item);
    if (pane != null) {
      LayoutScope.maybeOf(context)?.state.writeIfDeclaredFor(
        ClientSection.models,
        LayoutStateChannels.communicationSection,
        LayoutTabState(pane),
      );
    }
    widget.onSelectDestination(messagingFeatureItemSection(item));
  }

  void _reorder(int oldIndex, int newIndex) {
    setState(() {
      final next = [..._order];
      final moved = next.removeAt(oldIndex);
      next.insert(newIndex.clamp(0, next.length), moved);
      _order = List.unmodifiable(next);
    });
    unawaited(
      _orderStore.save(_portableData, [for (final item in _order) item.name]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final scopedState = LayoutScope.maybeOf(context)?.state;
    // The drag proxy renders in the root overlay, above the app-provided
    // LayoutPaletteScope; re-provide the palette around the dragged row so
    // proxy builds keep resolving it.
    final palette = context.layoutPalette;
    return LayoutValuesBuilder(
      state: scopedState,
      valuesOf: (context) => [
        messagingCommunicationModelsPaneIndex(scopedState),
      ],
      builder: (context) {
        final modelsPane = messagingCommunicationModelsPaneIndex(scopedState);
        return ReorderableListView(
          key: const Key('messaging-sidebar-feature-list'),
          buildDefaultDragHandles: false,
          proxyDecorator: (child, index, animation) => LayoutPaletteScope(
            palette: palette,
            child: AnimatedBuilder(
              animation: animation,
              builder: (context, child) {
                final t = Curves.easeInOut.transform(animation.value);
                return Transform.scale(
                  scale: 1.0 + (0.03 * t),
                  child: Opacity(opacity: 0.9 + (0.1 * t), child: child),
                );
              },
              child: child,
            ),
          ),
          padding: const EdgeInsets.fromLTRB(
            LicoContentSpacing.compact,
            0,
            LicoContentSpacing.compact,
            LicoContentSpacing.item,
          ),
          onReorderItem: _reorder,
          children: [
            for (final (index, item) in _order.indexed)
              ReorderableDelayedDragStartListener(
                key: Key('messaging-sidebar-list-${item.name}'),
                index: index,
                child: MessagingSidebarIndexRow(
                  icon: messagingFeatureItemIcon(item),
                  label: messagingFeatureItemLabel(strings, item),
                  selected: messagingFeatureItemSelected(
                    item: item,
                    current: widget.current,
                    modelsPane: modelsPane,
                  ),
                  onTap: () => _select(item),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Hosted sidebar for every non-agents destination that uses the foundation.
final class MessagingDesktopNavSidebar extends StatelessWidget {
  const MessagingDesktopNavSidebar({
    super.key,
    required this.destination,
    required this.onSelectDestination,
  });

  final ClientSection destination;
  final ValueChanged<ClientSection> onSelectDestination;

  @override
  Widget build(BuildContext context) {
    final scopedState = LayoutScope.maybeOf(context)?.state;
    if (scopedState == null) {
      return _column(
        context,
        settingsSectionIndex: 0,
        onSelectSettings: (_) {},
      );
    }
    return LayoutValuesBuilder(
      state: scopedState,
      valuesOf: (context) => [messagingSettingsSectionIndex(scopedState)],
      builder: (context) => _column(
        context,
        settingsSectionIndex: messagingSettingsSectionIndex(scopedState),
        onSelectSettings: (index) => scopedState.writeIfDeclared(
          LayoutStateChannels.settingsSection,
          LayoutTabState(index),
        ),
      ),
    );
  }

  Widget _column(
    BuildContext context, {
    required int settingsSectionIndex,
    required ValueChanged<int> onSelectSettings,
  }) {
    final chrome = LayoutChromePortScope.maybeOf(context);
    final showSearch =
        messagingSidebarShowsSearch(destination) && chrome != null;
    return ColoredBox(
      key: const Key('messaging-desktop-nav-sidebar'),
      color: Colors.transparent,
      child: MessagingSidebarFoundation(
        onSearch: showSearch
            ? () => unawaited(chrome.openGlobalSearch(context))
            : null,
        list: MessagingSidebarDestinationLists(
          destination: destination,
          onSelectDestination: onSelectDestination,
          settingsSectionIndex: settingsSectionIndex,
          onSelectSettings: onSelectSettings,
        ),
        bottomNav: MessagingSidebarBottomNav(
          current: destination,
          onSelectDestination: onSelectDestination,
        ),
      ),
    );
  }
}

/// The sidebar list slot keeps both hosted lists mounted in offstage slots:
/// switching between a feature destination and 设置 no longer unmounts the
/// 功能 list (which reloads its persisted order on mount) or the settings
/// section list (which loses its scroll position). Only the visible list is
/// active; the hidden one carries no ticker cost.
final class MessagingSidebarDestinationLists extends StatelessWidget {
  const MessagingSidebarDestinationLists({
    super.key,
    required this.destination,
    required this.onSelectDestination,
    required this.settingsSectionIndex,
    required this.onSelectSettings,
  });

  final ClientSection destination;
  final ValueChanged<ClientSection> onSelectDestination;
  final int settingsSectionIndex;
  final ValueChanged<int> onSelectSettings;

  @override
  Widget build(BuildContext context) {
    final isSettings = destination == ClientSection.settings;
    return Stack(
      fit: StackFit.expand,
      children: [
        Offstage(
          offstage: isSettings,
          child: TickerMode(
            enabled: !isSettings,
            child: MessagingFeatureSidebarList(
              current: destination,
              onSelectDestination: onSelectDestination,
            ),
          ),
        ),
        Offstage(
          offstage: !isSettings,
          child: TickerMode(
            enabled: isSettings,
            child: MessagingSettingsSectionList(
              selectedIndex: settingsSectionIndex,
              onSelectIndex: onSelectSettings,
            ),
          ),
        ),
      ],
    );
  }
}
