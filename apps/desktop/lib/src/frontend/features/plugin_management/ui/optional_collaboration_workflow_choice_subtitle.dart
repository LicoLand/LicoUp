import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/optional_collaboration_models.dart';

final class OptionalCollaborationWorkflowChoiceSubtitle
    extends StatelessWidget {
  const OptionalCollaborationWorkflowChoiceSubtitle({
    super.key,
    required this.choice,
  });

  final OptionalCollaborationWorkflowChoice choice;

  @override
  Widget build(BuildContext context) {
    final description = choice.description.isEmpty
        ? choice.packagePath
        : '${choice.description}\n${choice.id} · ${choice.packagePath}';
    return Text(description);
  }
}
