import 'package:flutter/widgets.dart';

import 'conversation_particle_field.dart';

/// The shared decorative globe for an empty conversation or loading surface.
///
/// [active] controls only ambient motion. Reduced motion keeps a still shell;
/// the caller owns loading, labels and all functional state independently.
class ConversationParticleGlobe extends StatelessWidget {
  const ConversationParticleGlobe({
    super.key,
    this.diameter = 280,
    this.active = true,
  });

  final double diameter;
  final bool active;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: diameter,
    child: TickerMode(
      enabled: active,
      child: LayoutBuilder(
        builder: (context, constraints) => ConversationParticleField(
          assembled: false,
          anchors: ConversationParticleAnchors(
            sphere: Offset.zero & constraints.biggest,
          ),
        ),
      ),
    ),
  );
}
