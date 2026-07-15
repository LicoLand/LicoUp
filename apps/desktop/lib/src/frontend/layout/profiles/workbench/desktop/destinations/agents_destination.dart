import 'package:flutter/material.dart';

import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/layout/layout_destination_presentation.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/workbench/desktop/destinations/workbench_agents_presentation.dart';
import 'package:flutter_client/src/frontend/layout/profiles/workbench/desktop/destinations/workbench_destination_frame.dart';

Widget workbenchDesktopAgentsDestinationBuilder(
  BuildContext context,
  LayoutDestinationBuildContext data,
) {
  validateWorkbenchDesktopDestination(data, ClientSection.agents);
  return LayoutDestinationPresentationScope(
    agents: const WorkbenchDesktopAgentsPresentation(),
    child: WorkbenchDesktopDestinationFrame(
      data: data,
      title: LicoStrings.of(context).agents,
      icon: Icons.hub_rounded,
      treatment: WorkbenchDesktopDestinationTreatment.collaboration,
    ),
  );
}
