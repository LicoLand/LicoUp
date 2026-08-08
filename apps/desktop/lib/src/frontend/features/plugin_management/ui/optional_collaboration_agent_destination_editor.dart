import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/optional_collaboration_workflow_models.dart';

final class OptionalCollaborationAgentDestinationEditors {
  final TextEditingController agentId = TextEditingController();
  final TextEditingController installDestination = TextEditingController();

  OptionalCollaborationAgentDestination get value =>
      OptionalCollaborationAgentDestination(
        agentId: agentId.text,
        installDestination: installDestination.text,
      );

  void dispose() {
    agentId.dispose();
    installDestination.dispose();
  }
}

final class OptionalCollaborationAgentDestinationFields
    extends StatelessWidget {
  const OptionalCollaborationAgentDestinationFields({
    super.key,
    required this.index,
    required this.editors,
    required this.enabled,
    required this.isChinese,
    required this.removable,
    required this.onRemove,
  });

  final int index;
  final OptionalCollaborationAgentDestinationEditors editors;
  final bool enabled;
  final bool isChinese;
  final bool removable;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '${isChinese ? '智能体' : 'Agent'} ${index + 1}',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            if (removable)
              IconButton(
                key: Key('collaboration-mcp-remove-agent-$index'),
                onPressed: enabled ? onRemove : null,
                tooltip: isChinese ? '移除智能体' : 'Remove agent',
                icon: const Icon(Icons.remove_circle_outline),
              ),
          ],
        ),
        TextField(
          key: Key('collaboration-mcp-agent-id-$index'),
          controller: editors.agentId,
          enabled: enabled,
          decoration: InputDecoration(
            labelText: isChinese ? '智能体规范 ID' : 'Canonical agent ID',
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          key: Key('collaboration-mcp-install-destination-$index'),
          controller: editors.installDestination,
          enabled: enabled,
          decoration: InputDecoration(
            labelText: isChinese
                ? '新的本机插件安装绝对路径'
                : 'New absolute local plugin destination',
          ),
        ),
      ],
    );
  }
}
