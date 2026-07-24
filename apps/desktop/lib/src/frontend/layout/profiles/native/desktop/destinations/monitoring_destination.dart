import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/layout/profiles/native/desktop/destinations/native_destination_frame.dart';

Widget buildNativeMonitoringDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) => NativeDestinationFrame(
  data: data,
  expectedDestination: ClientSection.monitoring,
);
