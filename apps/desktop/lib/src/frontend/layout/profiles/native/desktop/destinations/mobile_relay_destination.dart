import 'package:flutter/material.dart';

import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/native/desktop/destinations/native_destination_frame.dart';

Widget buildNativeMobileRelayDestination(
  BuildContext context,
  LayoutDestinationBuildContext data,
) => NativeDestinationFrame(
  data: data,
  expectedDestination: ClientSection.mobileRelay,
);
