import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/layout/layout_scope.dart';
import 'package:licoup/src/frontend/shared/mascot/mascot_catalog.dart';
import 'package:licoup/src/frontend/shared/mascot/self_mascot_identity.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// The local user's mark: the bundled mascot figure when the user picked
/// one, otherwise a person glyph on a quiet tile.
///
/// Avatar geometry follows the profile's own shape language: Desktop's
/// avatars are circles, so the mascot figure is fitted inside a circular
/// frame — scaled to keep the head accessory inside the ring rather than
/// cropped by it, and rendered through the figure slot that the mascot
/// rig animates. The Dashboard family speaks in rounded rectangles like
/// its buttons, so the figure stands on its own silhouette with no extra
/// clip.
final class MessagingSelfAvatar extends StatelessWidget {
  const MessagingSelfAvatar({super.key, required this.size, this.mascotId});

  final double size;

  /// Optional bundled mascot id (`MascotCatalog.avatars` key). When set the
  /// mascot image replaces the glyph tile — the self-card avatar picker.
  final String? mascotId;

  /// Profiles with [LayoutVisualTokens.circularAvatars] frame avatars as circles;
  /// other profiles (and unscoped contexts such as detached dialogs) take the
  /// rounded-square language.
  static bool circularFor(BuildContext context) =>
      LayoutScope.maybeOf(context)?.tokens.circularAvatars ?? false;

  /// The figure's scale inside a circular frame — small enough that the
  /// head accessory and the cone stay inside the ring.
  static const double _figureFitInCircle = 0.82;

  @override
  Widget build(BuildContext context) {
    final circular = circularFor(context);
    return ValueListenableBuilder<String>(
      valueListenable: selfMascotIdentity,
      builder: (context, sessionMascot, _) {
        final mascot = mascotId ?? sessionMascot;
        if (MascotCatalog.avatars.containsKey(mascot)) {
          final figure = Center(
            child: MascotImage.figure(
              mascot,
              semanticLabel: 'avatar',
              size: circular ? size * _figureFitInCircle : size,
            ),
          );
          return SizedBox.square(
            dimension: size,
            child: circular ? ClipOval(child: figure) : figure,
          );
        }
        final colors = context.licoColors;
        return Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: colors.text,
            borderRadius: BorderRadius.circular(
              circular ? size / 2 : size * 0.3,
            ),
          ),
          child: Icon(
            Icons.person_outline_rounded,
            size: size * 0.55,
            color: colors.background,
          ),
        );
      },
    );
  }
}
