import 'package:flutter/material.dart';

import 'package:flutter_client/src/contracts/agent_conversation_models.dart';
import 'package:flutter_client/src/contracts/agent_conversation_tab_activity.dart';
import 'package:flutter_client/src/contracts/target_candidate.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/history_session_panel.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/shared/ui/agent_brand_icon.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

/// Right-pane destination driven by the agents workspace sidebar.
enum AgentsWorkspaceDestination { conversations, plugins, skills, stats }

/// Background-style left rail: upper Explore-like nav + lower agent/project tree.
class AgentsWorkspaceSidebar extends StatefulWidget {
  const AgentsWorkspaceSidebar({
    super.key,
    required this.destination,
    required this.onSelectDestination,
    required this.targets,
    required this.sessionsByAgent,
    required this.selectedAgentId,
    required this.selectedSessionId,
    required this.activityFor,
    required this.onSelectAgent,
    required this.onSelectSession,
    required this.onNewConversation,
    this.onArchive,
    this.onAddTarget,
    this.allowManualTargetActions = true,
    this.scanning = false,
    this.adding = false,
  });

  final AgentsWorkspaceDestination destination;
  final ValueChanged<AgentsWorkspaceDestination> onSelectDestination;
  final List<TargetCandidate> targets;
  final Map<String, List<AgentConversationSession>> sessionsByAgent;
  final String selectedAgentId;
  final String selectedSessionId;
  final AgentConversationTabActivity Function(String agentId) activityFor;
  final ValueChanged<String> onSelectAgent;
  final void Function(String agentId, String sessionId) onSelectSession;
  final VoidCallback onNewConversation;
  final VoidCallback? onArchive;
  final VoidCallback? onAddTarget;
  final bool allowManualTargetActions;
  final bool scanning;
  final bool adding;

  @override
  State<AgentsWorkspaceSidebar> createState() => _AgentsWorkspaceSidebarState();
}

class _AgentsWorkspaceSidebarState extends State<AgentsWorkspaceSidebar> {
  final Set<String> _expandedAgents = <String>{};
  final Set<String> _expandedProjects = <String>{};
  bool _seeded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _seedExpansion();
  }

  @override
  void didUpdateWidget(covariant AgentsWorkspaceSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedAgentId != widget.selectedAgentId ||
        oldWidget.selectedSessionId != widget.selectedSessionId ||
        oldWidget.sessionsByAgent != widget.sessionsByAgent) {
      _seedExpansion(forceSelected: true);
    }
  }

  void _seedExpansion({bool forceSelected = false}) {
    if (_seeded && !forceSelected) {
      return;
    }
    _seeded = true;
    final agentId = widget.selectedAgentId.trim();
    if (agentId.isEmpty) {
      return;
    }
    _expandedAgents.add(agentId);
    final sessionId = widget.selectedSessionId.trim();
    if (sessionId.isEmpty) {
      return;
    }
    final sessions = widget.sessionsByAgent[agentId] ?? const [];
    for (final session in sessions) {
      if (session.id == sessionId) {
        _expandedProjects.add(
          _projectStorageKey(agentId, session.workingDirectory),
        );
        break;
      }
    }
  }

  String _projectStorageKey(String agentId, String workingDirectory) {
    return '$agentId::${workingDirectory.trim()}';
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return ColoredBox(
      key: const Key('agents-workspace-sidebar'),
      color: Colors.transparent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
            child: Column(
              children: [
                _SidebarNavItem(
                  key: const Key('agents-sidebar-nav-plugins'),
                  icon: Icons.extension_outlined,
                  label: strings.mcpPlugins,
                  selected:
                      widget.destination == AgentsWorkspaceDestination.plugins,
                  onTap: () => widget.onSelectDestination(
                    AgentsWorkspaceDestination.plugins,
                  ),
                ),
                _SidebarNavItem(
                  key: const Key('agents-sidebar-nav-skills'),
                  icon: Icons.auto_awesome_outlined,
                  label: strings.skillHub,
                  selected:
                      widget.destination == AgentsWorkspaceDestination.skills,
                  onTap: () => widget.onSelectDestination(
                    AgentsWorkspaceDestination.skills,
                  ),
                ),
                _SidebarNavItem(
                  key: const Key('agents-sidebar-nav-stats'),
                  icon: Icons.bar_chart_rounded,
                  label: strings.tokenUsage,
                  selected:
                      widget.destination == AgentsWorkspaceDestination.stats,
                  onTap: () => widget.onSelectDestination(
                    AgentsWorkspaceDestination.stats,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 10, 14, 6),
            child: Text(
              strings.agentsSidebarConversations,
              style: TextStyle(
                color: colors.textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.8,
              ),
            ),
          ),
          if (widget.destination == AgentsWorkspaceDestination.conversations)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (widget.onArchive != null)
                    _SidebarActionButton(
                      key: const Key('agents-sidebar-archive'),
                      tooltip: strings.archiveAgentConversations,
                      onPressed: widget.onArchive!,
                      icon: Icons.archive_outlined,
                      color: colors.text,
                    ),
                  _SidebarActionButton(
                    key: const Key('agents-sidebar-new-conversation'),
                    tooltip: strings.newConversation,
                    onPressed: widget.onNewConversation,
                    icon: Icons.add_comment_outlined,
                    color: colors.primary,
                  ),
                  if (widget.allowManualTargetActions &&
                      widget.onAddTarget != null)
                    _SidebarActionButton(
                      key: const Key('agents-sidebar-add-target'),
                      tooltip: strings.addTarget,
                      onPressed: widget.adding ? null : widget.onAddTarget,
                      icon: Icons.more_horiz_rounded,
                      color: colors.text,
                    ),
                ],
              ),
            ),
          Expanded(
            child: widget.targets.isEmpty
                ? _SidebarEmptyAgents(
                    scanning: widget.scanning,
                    adding: widget.adding,
                    allowManualTargetActions: widget.allowManualTargetActions,
                    onAddTarget: widget.onAddTarget,
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
                    itemCount: widget.targets.length,
                    itemBuilder: (context, index) {
                      final target = widget.targets[index];
                      return _AgentTreeNode(
                        target: target,
                        sessions:
                            widget.sessionsByAgent[target.id] ??
                            widget.sessionsByAgent[target.target] ??
                            const <AgentConversationSession>[],
                        expanded: _expandedAgents.contains(target.id),
                        selectedAgent:
                            widget.destination ==
                                AgentsWorkspaceDestination.conversations &&
                            widget.selectedAgentId == target.id,
                        selectedSessionId: widget.selectedSessionId,
                        activity: widget.activityFor(target.id),
                        expandedProjects: _expandedProjects,
                        projectKeyFor: (cwd) =>
                            _projectStorageKey(target.id, cwd),
                        onToggleAgent: () {
                          setState(() {
                            if (_expandedAgents.contains(target.id)) {
                              _expandedAgents.remove(target.id);
                            } else {
                              _expandedAgents.add(target.id);
                            }
                          });
                          widget.onSelectAgent(target.id);
                          widget.onSelectDestination(
                            AgentsWorkspaceDestination.conversations,
                          );
                        },
                        onToggleProject: (key) {
                          setState(() {
                            if (_expandedProjects.contains(key)) {
                              _expandedProjects.remove(key);
                            } else {
                              _expandedProjects.add(key);
                            }
                          });
                        },
                        onSelectSession: (sessionId) {
                          widget.onSelectDestination(
                            AgentsWorkspaceDestination.conversations,
                          );
                          widget.onSelectSession(target.id, sessionId);
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _SidebarActionButton extends StatelessWidget {
  const _SidebarActionButton({
    super.key,
    required this.tooltip,
    required this.onPressed,
    required this.icon,
    required this.color,
  });

  final String tooltip;
  final VoidCallback? onPressed;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        customBorder: const CircleBorder(),
        child: SizedBox.square(
          dimension: 32,
          child: Icon(icon, size: 18, color: color),
        ),
      ),
    );
  }
}

class _SidebarNavItem extends StatelessWidget {
  const _SidebarNavItem({
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
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            curve: Curves.easeOut,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            decoration: BoxDecoration(
              color: selected
                  ? colors.surface.withAlpha(colors.isDark ? 160 : 220)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
              border: selected
                  ? Border.all(color: colors.line.withAlpha(70))
                  : null,
            ),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 18,
                  color: selected ? colors.primaryStrong : colors.textMuted,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected ? colors.text : colors.textMuted,
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SidebarEmptyAgents extends StatelessWidget {
  const _SidebarEmptyAgents({
    required this.scanning,
    required this.adding,
    required this.allowManualTargetActions,
    required this.onAddTarget,
  });

  final bool scanning;
  final bool adding;
  final bool allowManualTargetActions;
  final VoidCallback? onAddTarget;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            scanning ? strings.scanningLocalAgents : strings.noLocalAgentsFound,
            style: TextStyle(color: colors.textMuted, fontSize: 12),
          ),
          if (allowManualTargetActions && onAddTarget != null) ...[
            const SizedBox(height: 10),
            TextButton.icon(
              onPressed: adding ? null : onAddTarget,
              icon: const Icon(Icons.add, size: 16),
              label: Text(strings.addTarget),
            ),
          ],
        ],
      ),
    );
  }
}

class _AgentTreeNode extends StatelessWidget {
  const _AgentTreeNode({
    required this.target,
    required this.sessions,
    required this.expanded,
    required this.selectedAgent,
    required this.selectedSessionId,
    required this.activity,
    required this.expandedProjects,
    required this.projectKeyFor,
    required this.onToggleAgent,
    required this.onToggleProject,
    required this.onSelectSession,
  });

  final TargetCandidate target;
  final List<AgentConversationSession> sessions;
  final bool expanded;
  final bool selectedAgent;
  final String selectedSessionId;
  final AgentConversationTabActivity activity;
  final Set<String> expandedProjects;
  final String Function(String workingDirectory) projectKeyFor;
  final VoidCallback onToggleAgent;
  final ValueChanged<String> onToggleProject;
  final ValueChanged<String> onSelectSession;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final projects = _groupSessionsByProject(sessions, strings);
    final activityColor = switch (activity) {
      AgentConversationTabActivity.needsApproval => colors.warning,
      AgentConversationTabActivity.workFinished => colors.info,
      AgentConversationTabActivity.none => null,
    };
    final activityTooltip = switch (activity) {
      AgentConversationTabActivity.needsApproval =>
        strings.agentTabNeedsApproval,
      AgentConversationTabActivity.workFinished => strings.agentTabWorkFinished,
      AgentConversationTabActivity.none => '',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onToggleAgent,
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    expanded
                        ? Icons.expand_more_rounded
                        : Icons.chevron_right_rounded,
                    size: 18,
                    color: colors.textMuted,
                  ),
                  const SizedBox(width: 2),
                  AgentBrandIcon(
                    target: target,
                    size: 22,
                    iconSize: 14,
                    selected: selectedAgent,
                    detected: target.status == 'detected' || target.configured,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      target.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: selectedAgent ? colors.text : colors.textMuted,
                        fontSize: 13,
                        fontWeight: selectedAgent
                            ? FontWeight.w600
                            : FontWeight.w500,
                      ),
                    ),
                  ),
                  if (activityColor != null)
                    Tooltip(
                      message: activityTooltip,
                      child: Container(
                        key: Key('agent-sidebar-activity-${target.target}'),
                        width: 7,
                        height: 7,
                        margin: const EdgeInsets.only(left: 6),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: activityColor,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        if (expanded)
          Padding(
            padding: const EdgeInsets.only(left: 12, bottom: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final project in projects)
                  _ProjectTreeNode(
                    label: project.label,
                    sessions: project.sessions,
                    expanded: expandedProjects.contains(
                      projectKeyFor(project.key),
                    ),
                    selectedSessionId: selectedSessionId,
                    onToggle: () => onToggleProject(projectKeyFor(project.key)),
                    onSelectSession: onSelectSession,
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _ProjectGroup {
  const _ProjectGroup({
    required this.key,
    required this.label,
    required this.sessions,
  });

  final String key;
  final String label;
  final List<AgentConversationSession> sessions;
}

List<_ProjectGroup> _groupSessionsByProject(
  List<AgentConversationSession> sessions,
  LicoStrings strings,
) {
  final groups = <String, List<AgentConversationSession>>{};
  final labels = <String, String>{};
  for (final session in sessions) {
    final key = session.workingDirectory.trim();
    (groups[key] ??= <AgentConversationSession>[]).add(session);
    labels.putIfAbsent(
      key,
      () => historySessionProjectLabel(
        key,
        fallback: strings.ungroupedConversationProject,
      ),
    );
  }
  return [
    for (final entry in groups.entries)
      _ProjectGroup(
        key: entry.key,
        label: labels[entry.key] ?? strings.ungroupedConversationProject,
        sessions: entry.value,
      ),
  ];
}

class _ProjectTreeNode extends StatelessWidget {
  const _ProjectTreeNode({
    required this.label,
    required this.sessions,
    required this.expanded,
    required this.selectedSessionId,
    required this.onToggle,
    required this.onSelectSession,
  });

  final String label;
  final List<AgentConversationSession> sessions;
  final bool expanded;
  final String selectedSessionId;
  final VoidCallback onToggle;
  final ValueChanged<String> onSelectSession;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onToggle,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
              child: Row(
                children: [
                  Icon(
                    expanded
                        ? Icons.expand_more_rounded
                        : Icons.chevron_right_rounded,
                    size: 16,
                    color: colors.textMuted,
                  ),
                  Icon(
                    Icons.folder_outlined,
                    size: 15,
                    color: colors.textMuted,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.left,
                      style: TextStyle(
                        color: colors.textMuted,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (expanded)
          Padding(
            // Align titles under the project label, not under the chevron.
            padding: const EdgeInsets.only(left: 22, bottom: 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final session in sessions)
                  _SessionTreeRow(
                    title: session.title.trim().isEmpty
                        ? session.id
                        : session.title,
                    selected: session.id == selectedSessionId,
                    onTap: () => onSelectSession(session.id),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _SessionTreeRow extends StatelessWidget {
  const _SessionTreeRow({
    required this.title,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 1),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: double.infinity,
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.fromLTRB(4, 7, 8, 7),
            decoration: BoxDecoration(
              color: selected
                  ? colors.surface.withAlpha(colors.isDark ? 180 : 230)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.left,
              style: TextStyle(
                color: selected ? colors.primaryStrong : colors.textMuted,
                fontSize: 12.5,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
