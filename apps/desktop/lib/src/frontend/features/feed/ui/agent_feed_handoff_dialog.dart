import 'package:flutter/material.dart';

import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/contracts/agent_feed_models.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

class AgentFeedHandoffDialog extends StatefulWidget {
  const AgentFeedHandoffDialog({
    super.key,
    required this.controller,
    required this.post,
  });

  final ClientController controller;
  final AgentFeedPost post;

  @override
  State<AgentFeedHandoffDialog> createState() => _AgentFeedHandoffDialogState();
}

class _AgentFeedHandoffDialogState extends State<AgentFeedHandoffDialog> {
  String? _selectedAgentId;
  final TextEditingController _noteController = TextEditingController();
  bool _forwarding = false;

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final localAgents = widget.controller.scannedTargets
        .where(
          (t) => t.visibleInClient && t.target != widget.post.sourceAgentId,
        )
        .toList(growable: false);
    final remoteAccounts = widget.controller.mobileAgentAccounts
        .where((a) => a.id != widget.post.author.accountId)
        .toList(growable: false);
    final candidates = [
      for (final target in localAgents)
        _HandoffCandidate(
          id: target.target,
          label: target.label.trim().isNotEmpty ? target.label : target.target,
          subtitle: strings.myAgents,
          isAgent: true,
        ),
      for (final account in remoteAccounts)
        _HandoffCandidate(
          id: account.id,
          label: account.label.trim().isNotEmpty
              ? account.label
              : account.provider.label,
          subtitle: strings.otherUsers,
          isAgent: false,
        ),
    ];

    return AlertDialog(
      backgroundColor: colors.surface,
      title: Text(
        strings.forwardTo,
        style: TextStyle(
          color: colors.text,
          fontSize: 17,
          fontWeight: FontWeight.w700,
        ),
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              strings.selectAgentToForward,
              style: TextStyle(color: colors.textMuted, fontSize: 13),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: candidates.isEmpty
                  ? Text(
                      strings.noLocalAgentsFound,
                      style: TextStyle(color: colors.textMuted, fontSize: 13),
                    )
                  : RadioGroup<String>(
                      groupValue: _selectedAgentId,
                      onChanged: (value) {
                        if (!_forwarding) {
                          setState(() => _selectedAgentId = value);
                        }
                      },
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: candidates.length,
                        itemBuilder: (context, index) {
                          final candidate = candidates[index];
                          final selected = _selectedAgentId == candidate.id;
                          return RadioListTile<String>(
                            value: candidate.id,
                            enabled: !_forwarding,
                            selected: selected,
                            title: Text(
                              candidate.label,
                              style: TextStyle(
                                color: colors.text,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            subtitle: Text(
                              candidate.subtitle,
                              style: TextStyle(
                                color: colors.textMuted,
                                fontSize: 11,
                              ),
                            ),
                            activeColor: colors.primary,
                            contentPadding: EdgeInsets.zero,
                          );
                        },
                      ),
                    ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _noteController,
              enabled: !_forwarding,
              maxLines: 2,
              decoration: InputDecoration(
                hintText: strings.forwardNoteHint,
                hintStyle: TextStyle(color: colors.textMuted),
                filled: true,
                fillColor: colors.background,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.all(12),
              ),
              style: TextStyle(color: colors.text, fontSize: 13),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _forwarding ? null : () => Navigator.of(context).pop(),
          child: Text(
            strings.cancel,
            style: TextStyle(color: colors.textMuted),
          ),
        ),
        FilledButton(
          onPressed: _selectedAgentId == null || _forwarding ? null : _forward,
          child: _forwarding
              ? SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: colors.textOnPrimary,
                  ),
                )
              : Text(strings.forward),
        ),
      ],
    );
  }

  Future<void> _forward() async {
    final agentId = _selectedAgentId;
    if (agentId == null || _forwarding) {
      return;
    }
    setState(() => _forwarding = true);
    await widget.controller.repostFeedPost(
      widget.post.id,
      agentId,
      note: _noteController.text.trim(),
    );
    if (!mounted) {
      return;
    }
    Navigator.of(context).pop();
  }
}

class _HandoffCandidate {
  const _HandoffCandidate({
    required this.id,
    required this.label,
    required this.subtitle,
    required this.isAgent,
  });

  final String id;
  final String label;
  final String subtitle;
  final bool isAgent;
}
