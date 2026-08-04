import 'package:flutter/material.dart';

import 'package:licoup/src/application/features/layout/layout_state_store.dart';
import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/layout_scope.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/layout_visual_tokens.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/shell/dashboard_folder_sidebar.dart';

/// Sidebar card tint alphas (dark/light); the blur itself comes from the
/// native NSVisualEffectView beneath the window's transparent zone.
const int _sidebarTintDarkAlpha = 22;
const int _sidebarTintLightAlpha = 150;

/// Dashboard's macOS-Notes desktop composition: the folder sidebar floats as
/// a lighter frosted-glass card inset from the window edges, above flush list
/// and detail panes on the window background — no top bar, no status bar.
Widget buildDashboardDesktopMediumShell(
  BuildContext context,
  LayoutShellBuildContext data,
) => _DashboardNotesShell(data: data);

Widget buildDashboardDesktopExpandedShell(
  BuildContext context,
  LayoutShellBuildContext data,
) => _DashboardNotesShell(data: data);

final class _DashboardNotesShell extends StatefulWidget {
  const _DashboardNotesShell({required this.data});

  final LayoutShellBuildContext data;

  @override
  State<_DashboardNotesShell> createState() => _DashboardNotesShellState();
}

final class _DashboardNotesShellState extends State<_DashboardNotesShell> {
  static const double _defaultSidebarWidth = 180;
  static const double _minSidebarWidth = 140;
  static const double _maxSidebarWidth = 320;

  double _sidebarWidth = _defaultSidebarWidth;

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    if (data.environment.surface != LayoutRuntimeSurface.desktop) {
      throw const FormatException('dashboard_desktop_surface_invalid');
    }
    final colors = context.layoutPalette;
    final tokens = context.layoutVisualTokens;
    final scopedState = LayoutScope.maybeOf(context)?.state;
    // Concentric corner radius: outer (window) radius 24 = card radius 16 +
    // padding 8, so the card's curve shares the window corner's center.
    const cardRadius = 16.0;

    return Semantics(
      key: const ValueKey<String>('dashboard-desktop-notes-shell'),
      container: true,
      label: data.destinationLabel(data.activeDestination),
      // Transparent base under the sidebar card: the native NSVisualEffectView
      // beneath the window supplies the real Apple-style blur there, while
      // the list/detail panes stay opaque on their own fills.
      child: Material(
        color: Colors.transparent,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ...[
              Padding(
                padding: EdgeInsets.only(
                  left: tokens.spacingUnit,
                  top: tokens.spacingUnit,
                  bottom: tokens.spacingUnit,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(cardRadius),
                  // No Flutter BackdropFilter here: the native visual-effect
                  // view already blurs the desktop beneath this transparent
                  // zone; the card is just a light tint plus a hairline rim.
                  child: Container(
                    decoration: BoxDecoration(
                      color: colors.isDark
                          ? Colors.white.withAlpha(_sidebarTintDarkAlpha)
                          : Colors.white.withAlpha(_sidebarTintLightAlpha),
                      borderRadius: BorderRadius.circular(cardRadius),
                      border: Border.all(
                        color: colors.line.withAlpha(colors.isDark ? 90 : 120),
                        width: 1,
                      ),
                    ),
                    child: scopedState == null
                        ? DashboardFolderSidebar(
                            section: data.activeDestination,
                            onSelectSection: data.onSelectDestination,
                            width: _sidebarWidth,
                          )
                        : ListenableBuilder(
                            listenable: scopedState.changes,
                            builder: (context, _) {
                              final tab = scopedState.readIfDeclared(
                                LayoutStateChannels.settingsSection,
                              );
                              return DashboardFolderSidebar(
                                section: data.activeDestination,
                                onSelectSection: data.onSelectDestination,
                                width: _sidebarWidth,
                                settingsSectionIndex: tab is LayoutTabState
                                    ? tab.index
                                    : 0,
                                onSelectSettingsSection: (index) =>
                                    scopedState.writeIfDeclared(
                                      LayoutStateChannels.settingsSection,
                                      LayoutTabState(index),
                                    ),
                              );
                            },
                          ),
                  ),
                ),
              ),
              // Drag-to-resize handle on the card's trailing edge.
              MouseRegion(
                key: const Key('dashboard-sidebar-resize-handle'),
                cursor: SystemMouseCursors.resizeLeftRight,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragUpdate: (details) {
                    setState(() {
                      _sidebarWidth = (_sidebarWidth + details.delta.dx).clamp(
                        _minSidebarWidth,
                        _maxSidebarWidth,
                      );
                    });
                  },
                  child: const SizedBox(width: 6),
                ),
              ),
            ],
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(
                  top: tokens.spacingUnit,
                  right: tokens.spacingUnit,
                  bottom: tokens.spacingUnit,
                ),
                child: Semantics(
                  key: ValueKey<String>(
                    'dashboard-desktop-focus-${data.initialFocusTarget}',
                  ),
                  container: true,
                  explicitChildNodes: true,
                  child: data.destination,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
