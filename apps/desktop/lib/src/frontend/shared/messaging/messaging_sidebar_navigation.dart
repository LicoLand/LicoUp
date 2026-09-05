import 'dart:async';

import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/layout/layout_state_port.dart';
import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/shared/settings_section_catalog.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_port.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/layout_scope.dart';
import 'package:licoup/src/frontend/shared/messaging/messaging_sidebar_foundation.dart';
import 'package:licoup/src/frontend/shared/ui/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';

/// Telegram-style tabs at the bottom of the shared sidebar foundation.
enum MessagingSidebarNavItem { skills, conversations, communication, settings }

/// Hosted index rows under the 通信 bottom-nav tile.
enum MessagingCommunicationItem { modelGateway, mobilePairing, chatChannels }

const messagingCommunicationModelsPaneGateway = 0;
const messagingCommunicationModelsPaneChatChannels = 1;

/// Destinations whose shared sidebar foundation stays on screen. Monitoring
/// is top-right chrome only and uses the main card full width.
bool messagingSidebarNavHosts(ClientSection section) =>
    section == ClientSection.agents ||
    section == ClientSection.skillHub ||
    section == ClientSection.pluginManagement ||
    section == ClientSection.agentHub ||
    section == ClientSection.models ||
    section == ClientSection.mobileRelay ||
    section == ClientSection.settings;

/// Destinations whose list sits in the shell-owned sidebar column. Agents
/// uses that same column widget from the workspace through the shell geometry.
/// Monitoring has no sidebar column.
bool messagingSidebarKeepsColumn(ClientSection section) =>
    section != ClientSection.agents && section != ClientSection.monitoring;

bool messagingSidebarShowsSearch(ClientSection section) =>
    section == ClientSection.agents ||
    section == ClientSection.settings ||
    section == ClientSection.skillHub ||
    section == ClientSection.pluginManagement ||
    section == ClientSection.agentHub;

ClientSection messagingSidebarNavTarget({
  required MessagingSidebarNavItem item,
  required ClientSection current,
}) => switch (item) {
  MessagingSidebarNavItem.communication =>
    current == ClientSection.models || current == ClientSection.mobileRelay
        ? current
        : ClientSection.models,
  MessagingSidebarNavItem.conversations => ClientSection.agents,
  MessagingSidebarNavItem.skills =>
    current == ClientSection.skillHub ||
            current == ClientSection.pluginManagement ||
            current == ClientSection.agentHub
        ? current
        : ClientSection.agentHub,
  MessagingSidebarNavItem.settings => ClientSection.settings,
};

bool messagingSidebarNavItemSelected({
  required MessagingSidebarNavItem item,
  required ClientSection current,
}) => switch (item) {
  MessagingSidebarNavItem.communication =>
    current == ClientSection.mobileRelay || current == ClientSection.models,
  MessagingSidebarNavItem.conversations => current == ClientSection.agents,
  MessagingSidebarNavItem.skills =>
    current == ClientSection.skillHub ||
        current == ClientSection.pluginManagement ||
        current == ClientSection.agentHub,
  MessagingSidebarNavItem.settings => current == ClientSection.settings,
};

IconData messagingSidebarNavIcon(MessagingSidebarNavItem item) =>
    switch (item) {
      MessagingSidebarNavItem.communication => Icons.qr_code_2_rounded,
      MessagingSidebarNavItem.conversations =>
        Icons.chat_bubble_outline_rounded,
      MessagingSidebarNavItem.skills => Icons.functions,
      MessagingSidebarNavItem.settings => Icons.settings_outlined,
    };

String messagingSidebarNavLabel(
  LicoStrings strings,
  MessagingSidebarNavItem item,
) => switch (item) {
  MessagingSidebarNavItem.communication => strings.pairing,
  MessagingSidebarNavItem.conversations => strings.conversationListNav,
  MessagingSidebarNavItem.skills => strings.features,
  MessagingSidebarNavItem.settings => strings.settings,
};

String messagingSidebarNavKey(MessagingSidebarNavItem item) =>
    'messaging-sidebar-nav-${item.name}';

String messagingCommunicationLabel(
  LicoStrings strings,
  MessagingCommunicationItem item,
) => switch (item) {
  MessagingCommunicationItem.modelGateway => strings.modelGateway,
  MessagingCommunicationItem.mobilePairing => strings.mobilePairing,
  MessagingCommunicationItem.chatChannels => strings.chatChannels,
};

IconData messagingCommunicationIcon(MessagingCommunicationItem item) =>
    switch (item) {
      MessagingCommunicationItem.modelGateway => Icons.key_outlined,
      MessagingCommunicationItem.mobilePairing => Icons.qr_code_2_rounded,
      MessagingCommunicationItem.chatChannels => Icons.forum_outlined,
    };

ClientSection messagingCommunicationTarget(MessagingCommunicationItem item) =>
    switch (item) {
      MessagingCommunicationItem.modelGateway ||
      MessagingCommunicationItem.chatChannels => ClientSection.models,
      MessagingCommunicationItem.mobilePairing => ClientSection.mobileRelay,
    };

int messagingCommunicationModelsPane(MessagingCommunicationItem item) =>
    item == MessagingCommunicationItem.chatChannels
    ? messagingCommunicationModelsPaneChatChannels
    : messagingCommunicationModelsPaneGateway;

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

MessagingCommunicationItem messagingCommunicationSelection({
  required ClientSection current,
  required int modelsPane,
}) {
  if (current == ClientSection.mobileRelay) {
    return MessagingCommunicationItem.mobilePairing;
  }
  if (current == ClientSection.models &&
      modelsPane == messagingCommunicationModelsPaneChatChannels) {
    return MessagingCommunicationItem.chatChannels;
  }
  return MessagingCommunicationItem.modelGateway;
}

String messagingSidebarHeading(
  LicoStrings strings,
  ClientSection destination, {
  int modelsPane = messagingCommunicationModelsPaneGateway,
}) => switch (destination) {
  ClientSection.settings => strings.settings,
  ClientSection.skillHub => strings.skillsNav,
  ClientSection.pluginManagement => strings.pluginsNav,
  ClientSection.agentHub => strings.agentHub,
  ClientSection.models =>
    modelsPane == messagingCommunicationModelsPaneChatChannels
        ? strings.chatChannels
        : strings.modelGateway,
  ClientSection.mobileRelay => strings.mobilePairing,
  ClientSection.monitoring => strings.tokenUsage,
  ClientSection.agents => strings.contacts,
};

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
  MessagingCommunicationItem communicationSelected =
      MessagingCommunicationItem.modelGateway,
  ValueChanged<MessagingCommunicationItem>? onSelectCommunication,
}) {
  if (destination == ClientSection.settings) {
    return MessagingSettingsSectionList(
      selectedIndex: settingsSectionIndex,
      onSelectIndex: onSelectSettings ?? (_) {},
    );
  }
  if (destination == ClientSection.skillHub ||
      destination == ClientSection.pluginManagement ||
      destination == ClientSection.agentHub) {
    return MessagingSkillPluginSidebarList(
      current: destination,
      onSelectDestination: onSelectDestination,
    );
  }
  if (destination == ClientSection.models ||
      destination == ClientSection.mobileRelay) {
    return MessagingCommunicationSidebarList(
      selected: communicationSelected,
      onSelect: onSelectCommunication ?? (_) {},
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
              margin: const EdgeInsets.symmetric(
                horizontal: LicoContentSpacing.inline,
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
          margin: const EdgeInsets.only(bottom: LicoContentSpacing.inline),
          padding: const EdgeInsets.symmetric(
            horizontal: LicoContentSpacing.compact,
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
          child: Row(
            children: [
              Icon(widget.icon, size: 17, color: foreground),
              const SizedBox(width: LicoContentSpacing.compact),
              Expanded(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: foreground,
                    fontSize: 12.5,
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

/// Skills and Plugins as distinct left-sidebar destinations.
final class MessagingSkillPluginSidebarList extends StatelessWidget {
  const MessagingSkillPluginSidebarList({
    super.key,
    required this.current,
    required this.onSelectDestination,
  });

  final ClientSection current;
  final ValueChanged<ClientSection> onSelectDestination;

  static const _items = <ClientSection>[
    ClientSection.agentHub,
    ClientSection.skillHub,
    ClientSection.pluginManagement,
  ];

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    return ListView(
      key: const Key('messaging-sidebar-skill-plugin-list'),
      padding: const EdgeInsets.fromLTRB(
        LicoContentSpacing.compact,
        0,
        LicoContentSpacing.compact,
        LicoContentSpacing.item,
      ),
      children: [
        for (final section in _items)
          MessagingSidebarIndexRow(
            key: Key('messaging-sidebar-list-${section.name}'),
            icon: messagingSidebarDestinationIcon(section),
            label: messagingSidebarHeading(strings, section),
            selected: current == section,
            onTap: () => onSelectDestination(section),
          ),
      ],
    );
  }
}

/// Model gateway, mobile pairing, and chat channels under 通信.
final class MessagingCommunicationSidebarList extends StatelessWidget {
  const MessagingCommunicationSidebarList({
    super.key,
    required this.selected,
    required this.onSelect,
  });

  final MessagingCommunicationItem selected;
  final ValueChanged<MessagingCommunicationItem> onSelect;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    return ListView(
      key: const Key('messaging-sidebar-communication-list'),
      padding: const EdgeInsets.fromLTRB(
        LicoContentSpacing.compact,
        0,
        LicoContentSpacing.compact,
        LicoContentSpacing.item,
      ),
      children: [
        for (final item in MessagingCommunicationItem.values)
          MessagingSidebarIndexRow(
            key: Key('messaging-sidebar-list-${item.name}'),
            icon: messagingCommunicationIcon(item),
            label: messagingCommunicationLabel(strings, item),
            selected: selected == item,
            onTap: () => onSelect(item),
          ),
      ],
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
        modelsPane: messagingCommunicationModelsPaneGateway,
        onSelectCommunication: (item) =>
            onSelectDestination(messagingCommunicationTarget(item)),
      );
    }
    return StreamBuilder<void>(
      stream: scopedState.changes,
      builder: (context, _) => _column(
        context,
        settingsSectionIndex: messagingSettingsSectionIndex(scopedState),
        onSelectSettings: (index) => scopedState.writeIfDeclared(
          LayoutStateChannels.settingsSection,
          LayoutTabState(index),
        ),
        modelsPane: messagingCommunicationModelsPaneIndex(scopedState),
        onSelectCommunication: (item) {
          scopedState.writeIfDeclaredFor(
            ClientSection.models,
            LayoutStateChannels.communicationSection,
            LayoutTabState(messagingCommunicationModelsPane(item)),
          );
          onSelectDestination(messagingCommunicationTarget(item));
        },
      ),
    );
  }

  Widget _column(
    BuildContext context, {
    required int settingsSectionIndex,
    required ValueChanged<int> onSelectSettings,
    required int modelsPane,
    required ValueChanged<MessagingCommunicationItem> onSelectCommunication,
  }) {
    final strings = LicoStrings.of(context);
    final chrome = LayoutChromePortScope.maybeOf(context);
    final showSearch =
        messagingSidebarShowsSearch(destination) && chrome != null;
    return ColoredBox(
      key: const Key('messaging-desktop-nav-sidebar'),
      color: Colors.transparent,
      child: MessagingSidebarFoundation(
        heading: messagingSidebarHeading(
          strings,
          destination,
          modelsPane: modelsPane,
        ),
        headingKey: const Key('messaging-desktop-nav-sidebar-heading'),
        onSearch: showSearch
            ? () => unawaited(chrome.openGlobalSearch(context))
            : null,
        list: messagingSidebarListFor(
          destination: destination,
          onSelectDestination: onSelectDestination,
          settingsSectionIndex: settingsSectionIndex,
          onSelectSettings: onSelectSettings,
          communicationSelected: messagingCommunicationSelection(
            current: destination,
            modelsPane: modelsPane,
          ),
          onSelectCommunication: onSelectCommunication,
        ),
        bottomNav: MessagingSidebarBottomNav(
          current: destination,
          onSelectDestination: onSelectDestination,
        ),
      ),
    );
  }
}
