import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/classic/desktop/destinations/classic_agents_presentation.dart';
import 'package:licoup/src/frontend/layout/profiles/classic/desktop/destinations/classic_destination_frame.dart';

Widget classicDesktopAgentsDestinationBuilder(
  BuildContext context,
  LayoutDestinationBuildContext data,
) {
  validateClassicDesktopDestination(data, ClientSection.agents);
  return LayoutDestinationPresentationScope(
    agents: const ClassicDesktopAgentsPresentation(),
    child: ClassicDesktopDestinationFrame(
      data: data,
      title: LicoStrings.of(context).agents,
      icon: Icons.hub_rounded,
      treatment: ClassicDesktopDestinationTreatment.collaboration,
    ),
  );
}
