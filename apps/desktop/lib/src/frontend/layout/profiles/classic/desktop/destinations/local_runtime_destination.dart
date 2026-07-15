import 'package:flutter/material.dart';

import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/classic/desktop/destinations/classic_destination_frame.dart';

Widget classicDesktopLocalRuntimeDestinationBuilder(
  BuildContext context,
  LayoutDestinationBuildContext data,
) {
  validateClassicDesktopDestination(data, ClientSection.localRuntime);
  return ClassicDesktopDestinationFrame(
    data: data,
    title: LicoStrings.of(context).runtime,
    icon: Icons.memory_rounded,
    treatment: ClassicDesktopDestinationTreatment.runtime,
  );
}
