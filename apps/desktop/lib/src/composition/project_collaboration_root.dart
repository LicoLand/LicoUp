import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:presentation_runtime/presentation_runtime.dart';

import 'package:licoup/src/composition/extensions/extension_ui_composition.dart';
import 'package:licoup/src/composition/extensions/project_collaboration_composition.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';

// One contribution composition per application container, not per destination
// visit. Its runtime is the existing app-scoped runtime supplied to the
// container; this feature never constructs or disposes a second runtime.
final _projectCollaborationRootProvider =
    Provider<ProjectCollaborationExtension>((ref) {
      final composition = ExtensionUiComposition(
        runtime: ref.watch(presentationRuntimeProvider),
      );
      final extension = ProjectCollaborationExtension.mount(
        composition: composition,
      );
      ref.onDispose(() {
        extension.session.dispose();
        unawaited(composition.dispose());
      });
      // Publish the host capability, never a synthetic project or authority.
      // The native producer is not installed yet; do not pre-open the unseeded
      // source with an extra ownership lease.
      extension.publishEpoch();
      return extension;
    });

class ProjectCollaborationRoot extends ConsumerWidget {
  const ProjectCollaborationRoot({super.key, required this.child});

  final Widget child;

  /// The mounted application owner, shared by all feature-host visits.
  /// Reading it never starts or seeds a project source.
  static ProjectCollaborationExtension? compositionOf(BuildContext context) =>
      context
          .getInheritedWidgetOfExactType<_ProjectCollaborationScope>()
          ?.extension;

  static Widget layerOf(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<_ProjectCollaborationScope>();
    if (scope == null) {
      return Center(
        key: const Key('project-collaboration-root-unavailable'),
        child: Text(LicoStrings.of(context).projectCollaborationUnavailable),
      );
    }
    // Return a fresh widget; layouts may keep visited destinations offstage.
    return scope.extension.buildLayer();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      _ProjectCollaborationScope(
        extension: ref.watch(_projectCollaborationRootProvider),
        child: child,
      );
}

class _ProjectCollaborationScope extends InheritedWidget {
  const _ProjectCollaborationScope({
    required this.extension,
    required super.child,
  });

  final ProjectCollaborationExtension extension;

  @override
  bool updateShouldNotify(_ProjectCollaborationScope oldWidget) =>
      !identical(extension, oldWidget.extension);
}
