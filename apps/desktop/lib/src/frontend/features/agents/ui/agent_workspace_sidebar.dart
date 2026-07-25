import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/agent_conversation_tab_activity.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_display_names.dart';
import 'package:licoup/src/frontend/features/agents/ui/history_session_panel.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/agent_brand_icon.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Second-layer conversation list: a flat pane one tonal step above the
/// window background, grouping conversations by agent, then by project.
class AgentsWorkspaceSidebar extends StatefulWidget {
  const AgentsWorkspaceSidebar({
    super.key,
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
    var expansionId = agentId;
    for (final group in _groups()) {
      if (group.containsAgent(agentId)) {
        expansionId = group.representative.id;
        break;
      }
    }
    _expandedAgents.add(expansionId);
    final sessionId = widget.selectedSessionId.trim();
    if (sessionId.isEmpty) {
      return;
    }
    final sessions = widget.sessionsByAgent[agentId] ?? const [];
    for (final session in sessions) {
      if (session.id == sessionId) {
        _expandedProjects.add(
          _projectStorageKey(
            expansionId,
            agentConversationSessionIsActive(session)
                ? session.workingDirectory
                : agentConversationArchivedProjectKey,
          ),
        );
        break;
      }
    }
  }

  /// Targets that share a canonical product name (for example Codex CLI and
  /// Codex Desktop) collapse into one sidebar entry; the first target in the
  /// incoming order represents the group.
  List<_AgentSidebarGroup> _groups() {
    final groups = <_AgentSidebarGroup>[];
    final indexByName = <String, int>{};
    for (final target in widget.targets) {
      final name = agentConversationTargetDisplayName(target);
      final key = name.toLowerCase();
      final index = indexByName[key];
      if (index == null) {
        indexByName[key] = groups.length;
        groups.add(_AgentSidebarGroup(name, [target]));
      } else {
        groups[index].members.add(target);
      }
    }
    return groups;
  }

  String _projectStorageKey(String agentId, String workingDirectory) {
    return '$agentId::${workingDirectory.trim()}';
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final groups = _groups();
    return ColoredBox(
      key: const Key('agents-workspace-sidebar'),
      color: Colors.transparent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 8, 4),
            child: SizedBox(
              height: 32,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Text(
                      strings.agentsSidebarConversations,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.textMuted,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.8,
                        height: 1,
                      ),
                    ),
                  ),
                  if (widget.onArchive != null)
                    _SidebarActionButton(
                      key: const Key('agents-sidebar-archive'),
                      tooltip: strings.archiveAgentConversations,
                      onPressed: widget.onArchive!,
                      icon: Icons.archive_outlined,
                      color: colors.textMuted,
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
                      color: colors.textMuted,
                    ),
                ],
              ),
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
                    itemCount: groups.length,
                    itemBuilder: (context, index) {
                      final group = groups[index];
                      final representative = group.representative;
                      final sessions = <AgentConversationSession>[];
                      final seenSessionIds = <String>{};
                      final ownerBySessionId = <String, String>{};
                      for (final member in group.members) {
                        final memberSessions =
                            widget.sessionsByAgent[member.id] ??
                            widget.sessionsByAgent[member.target] ??
                            const <AgentConversationSession>[];
                        for (final session in memberSessions) {
                          if (seenSessionIds.add(session.id)) {
                            sessions.add(session);
                            ownerBySessionId[session.id] = member.id;
                          }
                        }
                      }
                      final activity = group.members
                          .map((member) => widget.activityFor(member.id))
                          .firstWhere(
                            (value) =>
                                value != AgentConversationTabActivity.none,
                            orElse: () => AgentConversationTabActivity.none,
                          );
                      return _AgentTreeNode(
                        target: representative,
                        displayName: group.displayName,
                        detected: group.members.any(
                          (member) =>
                              member.status == 'detected' || member.configured,
                        ),
                        sessions: sessions,
                        expanded: _expandedAgents.contains(representative.id),
                        selectedAgent: group.containsAgent(
                          widget.selectedAgentId,
                        ),
                        selectedSessionId: widget.selectedSessionId,
                        activity: activity,
                        expandedProjects: _expandedProjects,
                        projectKeyFor: (cwd) =>
                            _projectStorageKey(representative.id, cwd),
                        onToggleAgent: () {
                          setState(() {
                            if (_expandedAgents.contains(representative.id)) {
                              _expandedAgents.remove(representative.id);
                            } else {
                              _expandedAgents.add(representative.id);
                            }
                          });
                          widget.onSelectAgent(
                            group.selectedOrRepresentativeId(
                              widget.selectedAgentId,
                            ),
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
                          widget.onSelectSession(
                            ownerBySessionId[sessionId] ?? representative.id,
                            sessionId,
                          );
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

class _AgentSidebarGroup {
  _AgentSidebarGroup(this.displayName, this.members);

  final String displayName;
  final List<TargetCandidate> members;

  TargetCandidate get representative => members.first;

  bool containsAgent(String agentId) {
    final normalized = agentId.trim();
    return members.any(
      (member) => member.id == normalized || member.target == normalized,
    );
  }

  String selectedOrRepresentativeId(String selectedAgentId) {
    final normalized = selectedAgentId.trim();
    for (final member in members) {
      if (member.id == normalized || member.target == normalized) {
        return member.id;
      }
    }
    return representative.id;
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
    final colors = context.licoColors;
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        onTap: onPressed,
        customBorder: const CircleBorder(),
        hoverColor: colors.isDark
            ? Colors.white.withAlpha(10)
            : Colors.black.withAlpha(12),
        child: SizedBox.square(
          dimension: 28,
          child: Icon(icon, size: 16, color: color),
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
    required this.displayName,
    required this.detected,
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
  final String displayName;
  final bool detected;
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
    final activeSessions = <AgentConversationSession>[];
    final archivedSessions = <AgentConversationSession>[];
    for (final session in sessions) {
      (agentConversationSessionIsActive(session)
              ? activeSessions
              : archivedSessions)
          .add(session);
    }
    final projects = _groupSessionsByProject(activeSessions, strings);
    final archivedKey = projectKeyFor(agentConversationArchivedProjectKey);
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
                    detected: detected,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      displayName,
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
                if (archivedSessions.isNotEmpty)
                  _ProjectTreeNode(
                    label:
                        '${strings.archivedConversations} · ${archivedSessions.length}',
                    icon: Icons.archive_outlined,
                    sessions: archivedSessions,
                    expanded: expandedProjects.contains(archivedKey),
                    selectedSessionId: selectedSessionId,
                    onToggle: () => onToggleProject(archivedKey),
                    onSelectSession: onSelectSession,
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Sessions updated within this window count as current conversations;
/// anything older collapses into the per-agent archived group. Membership is
/// purely time-based: selecting an old session keeps it inside the archived
/// group instead of pulling it back into the active project groups.
const int agentConversationActiveWindowDays = 7;

/// Project-group key for the archived section at the end of an agent's list.
const String agentConversationArchivedProjectKey = '__archived__';

bool agentConversationSessionIsActive(
  AgentConversationSession session, {
  DateTime? now,
}) {
  final updated = DateTime.tryParse(session.updatedAt.trim())?.toLocal();
  if (updated == null) {
    return true;
  }
  return (now ?? DateTime.now()).difference(updated).inDays <
      agentConversationActiveWindowDays;
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
    this.icon = Icons.folder_outlined,
  });

  final String label;
  final List<AgentConversationSession> sessions;
  final bool expanded;
  final String selectedSessionId;
  final VoidCallback onToggle;
  final ValueChanged<String> onSelectSession;
  final IconData icon;

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
                  Icon(icon, size: 15, color: colors.textMuted),
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
                  ? (colors.isDark ? colors.surfaceLow : colors.surface)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: selected
                  ? Border.all(color: colors.line.withAlpha(80), width: 0.5)
                  : null,
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
