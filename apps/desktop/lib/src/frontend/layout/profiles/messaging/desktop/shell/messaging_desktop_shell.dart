import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_features.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_port.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/shell/messaging_content_region.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/shell/messaging_main_content_card.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/shell/messaging_profile_page.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/shell/messaging_sidebar_column.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/shell/messaging_sidebar_navigation.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/shell/messaging_top_strip.dart';

/// Messaging desktop shell hierarchy: a full-width frosted-glass chrome band
/// (traffic-light inset, conversation tabs, token-usage, and notifications),
/// then [MessagingContentRegion] with one rounded main card whose left column
/// is the shared resizable sidebar foundation.
Widget buildMessagingDesktopMediumShell(
  BuildContext context,
  LayoutShellBuildContext data,
) => _MessagingDesktopShell(data: data);

Widget buildMessagingDesktopExpandedShell(
  BuildContext context,
  LayoutShellBuildContext data,
) => _MessagingDesktopShell(data: data);

final class _MessagingDesktopShell extends StatefulWidget {
  const _MessagingDesktopShell({required this.data});

  final LayoutShellBuildContext data;

  @override
  State<_MessagingDesktopShell> createState() => _MessagingDesktopShellState();
}

final class _MessagingDesktopShellState extends State<_MessagingDesktopShell> {
  bool _profileOpen = false;
  ValueNotifier<bool>? _auxPanelOpen;

  void _closeProfile() {
    final notifier = _auxPanelOpen;
    if (notifier != null) {
      if (notifier.value) {
        notifier.value = false;
      }
      return;
    }
    if (_profileOpen) {
      setState(() => _profileOpen = false);
    }
  }

  void _selectDestination(ClientSection destination) {
    _closeProfile();
    widget.data.onSelectDestination(destination);
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final colors = context.layoutPalette;
    assert(
      data.environment.surface == LayoutRuntimeSurface.desktop,
      'messaging_desktop_surface_invalid',
    );
    if (data.environment.surface != LayoutRuntimeSurface.desktop) {
      return ColoredBox(color: colors.background);
    }
    final notifier = LayoutChromeFeaturesScope.maybeOf(
      context,
    )?.auxChromePanelOpen;
    if (!identical(_auxPanelOpen, notifier)) {
      _auxPanelOpen = notifier;
    }

    return Semantics(
      key: const ValueKey<String>('messaging-desktop-shell'),
      container: true,
      label: data.destinationLabel(data.activeDestination),
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.escape): _closeProfile,
        },
        child: Focus(
          skipTraversal: true,
          child: Material(
            // Transparent base: the native NSVisualEffectView blurs the
            // desktop beneath every chrome region and margin gutter.
            color: Colors.transparent,
            child: notifier == null
                ? _chromeContent(data, profileOpen: _profileOpen)
                : ValueListenableBuilder<bool>(
                    valueListenable: notifier,
                    builder: (context, open, _) =>
                        _chromeContent(data, profileOpen: open),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _chromeContent(
    LayoutShellBuildContext data, {
    required bool profileOpen,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MessagingChromeBand(
          chrome: data.chrome,
          showSearch: !messagingSidebarNavHosts(data.activeDestination),
          section: data.activeDestination,
          onSelectSection: _selectDestination,
        ),
        Expanded(
          child: MessagingContentRegion(
            child: MessagingMainContentCard(
              child: _mainCardBody(data, profileOpen: profileOpen),
            ),
          ),
        ),
      ],
    );
  }

  Widget _mainCardBody(
    LayoutShellBuildContext data, {
    required bool profileOpen,
  }) {
    return Semantics(
      key: ValueKey<String>(
        'messaging-desktop-focus-${data.initialFocusTarget}',
      ),
      container: true,
      explicitChildNodes: true,
      child: profileOpen
          ? MessagingProfilePage(
              onOpenPairing: () =>
                  _selectDestination(ClientSection.mobileRelay),
              onOpenSettings: () => _selectDestination(ClientSection.settings),
            )
          : LayoutChromePortScope(
              chrome: data.chrome,
              child: MessagingSidebarGeometry(
                child: _destinationWithSidebar(data),
              ),
            ),
    );
  }

  Widget _destinationWithSidebar(LayoutShellBuildContext data) {
    final destination = data.activeDestination;
    // Agents renders the conversation list through the same column widget,
    // reading width from MessagingSidebarGeometry. Monitoring is full-width.
    // Other hosted destinations keep that column so width does not jump.
    if (!messagingSidebarKeepsColumn(destination)) {
      return data.destination;
    }
    return MessagingSidebarColumn(
      sidebar: MessagingDesktopNavSidebar(
        destination: destination,
        onSelectDestination: _selectDestination,
      ),
      detail: data.destination,
    );
  }
}
