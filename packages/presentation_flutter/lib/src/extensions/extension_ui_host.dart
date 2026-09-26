/// The host surface that mounts one registry epoch of contributions.
///
/// [ExtensionUiHost] renders every mounted contribution of the registry's
/// current epoch and nothing else. A contribution update only reaches its own
/// primitive through its session, so mounting or withdrawing an epoch does not
/// rebuild the surrounding conversation, catalog or navigation surfaces.
///
/// Host trust and permission prompts are host-owned: the optional
/// [ExtensionUiHost.hostTrustPrompt] layer is drawn above every contribution in
/// the same stack, and no contribution field, kind or primitive can draw or
/// cover one.
library;

import 'package:flutter/widgets.dart';

import 'extension_ui_primitives.dart';
import 'extension_ui_registry.dart';

/// Mounts the current epoch of declarative contributions.
class ExtensionUiHost extends StatelessWidget {
  const ExtensionUiHost({
    super.key,
    required this.registry,
    this.hostTrustPrompt,
    this.emptyPlaceholder,
    this.padding = const EdgeInsets.symmetric(vertical: 4),
  });

  final ExtensionUiMountRegistry registry;

  /// A host-owned trust or permission prompt, drawn above every contribution.
  ///
  /// The host decides when it appears; a contribution has no way to supply one
  /// and no way to cover it.
  final Widget? hostTrustPrompt;

  /// Shown when the current epoch has no mounted contribution.
  final Widget? emptyPlaceholder;

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: registry,
      builder: (context, _) {
        final sessions = registry.mounted;
        return Stack(
          children: [
            if (sessions.isEmpty)
              emptyPlaceholder ?? const SizedBox.shrink()
            else
              Padding(
                padding: padding,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final session in sessions)
                      KeyedSubtree(
                        key: ValueKey<ExtensionUiMountIdentity>(
                          session.identity,
                        ),
                        child: ExtensionContributionView(session: session),
                      ),
                  ],
                ),
              ),
            if (hostTrustPrompt != null)
              Positioned.fill(child: hostTrustPrompt!),
          ],
        );
      },
    );
  }
}
