import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/lico_skeleton.dart';

/// The conversation-list loading bar: an anonymous rounded rectangle that
/// pulses a highlight from its leading edge to its trailing edge, standing in
/// for text whose value is still loading — a row's preview line, its activity
/// timestamp. The row keeps the contact's real avatar and name so the pending
/// content lands where it belongs instead of hiding behind a spinner.
///
/// All conversation-list rows share this one placeholder; tune the shape here
/// rather than per call site (docs/functionality/MESSAGING-LOADING-PRESENTATION.md).
final class MessagingLoadingBar extends StatelessWidget {
  const MessagingLoadingBar({
    super.key,
    this.width = double.infinity,
    this.height = 10,
  }) : radius = height / 2;

  final double width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return LicoSkeleton(width: width, height: height, radius: radius);
  }
}
