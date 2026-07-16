enum OptionalCollaborationWorkflowKind {
  localDeployment('local-deployment'),
  mcpInstall('mcp-install');

  const OptionalCollaborationWorkflowKind(this.wireName);

  final String wireName;

  static OptionalCollaborationWorkflowKind parse(Object? value) {
    return values.firstWhere(
      (kind) => kind.wireName == value,
      orElse: () => throw const FormatException(
        'optional_collaboration_workflow_kind_invalid',
      ),
    );
  }
}
