import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/layout_scope.dart';
import 'package:licoup/src/frontend/layout/layout_state_port.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/shell/desktop_traffic_light_anchor.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/tokens/desktop_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/settings_section_catalog.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';

/// The Desktop settings app: a desktop-owned copy of the settings framing —
/// left section-navigation card carrying the traffic-light row at its
/// top-left, settings main area on the right hosting the shared
/// SettingsPanel unchanged. Deliberately independent from the Dashboard
/// settings assets so the two can diverge.
final class DesktopSettingsApp extends StatelessWidget {
  const DesktopSettingsApp({super.key, required this.data});

  final LayoutDestinationBuildContext data;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      key: const Key('desktop-settings-app'),
      color: Colors.transparent,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 10, 0, 10),
            child: DesktopSettingsNavCard(),
          ),
          Expanded(
            child: KeyedSubtree(
              key: const Key('desktop-settings-main'),
              child: data.content.buildDestination(
                context,
                ClientSection.settings,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The copy's left card: traffic-light anchor row, 设置 heading, and the
/// canonical settings section index writing the shared section channel.
final class DesktopSettingsNavCard extends StatelessWidget {
  const DesktopSettingsNavCard({super.key});

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final scopedState = LayoutScope.maybeOf(context)?.state;
    return DecoratedBox(
      key: const Key('desktop-settings-nav-card'),
      decoration: BoxDecoration(
        color: desktopDesktopSurfaceBlack,
        borderRadius: BorderRadius.circular(
          DesktopDesktopMetrics.settingsNavCardRadius,
        ),
        border: Border.all(color: DesktopDesktopOnBlack.line, width: 0.5),
        boxShadow: const [
          BoxShadow(
            color: Color(0x59000000),
            blurRadius: 18,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: SizedBox(
        width: DesktopDesktopMetrics.settingsNavCardWidth,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(
            DesktopDesktopMetrics.settingsNavCardRadius,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.only(left: 6, top: 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: DesktopTrafficLightAnchor(
                    key: Key('desktop-settings-traffic-light-row'),
                    height: DesktopDesktopMetrics.settingsTrafficLightRowExtent,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  LicoContentSpacing.item,
                  LicoContentSpacing.inline,
                  LicoContentSpacing.compact,
                  LicoContentSpacing.compact,
                ),
                child: Text(
                  strings.settings,
                  key: const Key('desktop-settings-nav-heading'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: DesktopDesktopOnBlack.text,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Expanded(
                child: scopedState == null
                    ? const DesktopSettingsSectionList(
                        selectedIndex: 0,
                        onSelectIndex: _noopSelect,
                      )
                    : StreamBuilder<void>(
                        stream: scopedState.changes,
                        builder: (context, _) => DesktopSettingsSectionList(
                          selectedIndex: desktopSettingsSectionIndex(
                            scopedState,
                          ),
                          onSelectIndex: (index) => scopedState.writeIfDeclared(
                            LayoutStateChannels.settingsSection,
                            LayoutTabState(index),
                          ),
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

void _noopSelect(int _) {}

int desktopSettingsSectionIndex(LayoutScopedState? state) {
  final tab = state?.readIfDeclared(LayoutStateChannels.settingsSection);
  if (tab is LayoutTabState && tab.index < settingsSectionIdOrder.length) {
    return tab.index;
  }
  return 0;
}

/// The canonical settings catalog rows hosted in the copy's left card.
final class DesktopSettingsSectionList extends StatelessWidget {
  const DesktopSettingsSectionList({
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
      key: const Key('desktop-settings-section-list'),
      padding: const EdgeInsets.fromLTRB(
        LicoContentSpacing.compact,
        0,
        LicoContentSpacing.compact,
        LicoContentSpacing.item,
      ),
      itemCount: sections.length,
      itemBuilder: (context, index) {
        final section = sections[index];
        return _DesktopSettingsIndexRow(
          key: Key('desktop-settings-section-${section.id}'),
          icon: section.icon,
          label: section.label,
          selected: selectedIndex == index,
          onTap: () => onSelectIndex(index),
        );
      },
    );
  }
}

final class _DesktopSettingsIndexRow extends StatefulWidget {
  const _DesktopSettingsIndexRow({
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
  State<_DesktopSettingsIndexRow> createState() =>
      _DesktopSettingsIndexRowState();
}

final class _DesktopSettingsIndexRowState
    extends State<_DesktopSettingsIndexRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    final selected = widget.selected;
    final foreground = selected
        ? colors.textOnPrimary
        : DesktopDesktopOnBlack.text;
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
                ? DesktopDesktopOnBlack.hoverOverlay
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
