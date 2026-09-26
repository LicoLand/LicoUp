/// Composition of the project collaboration contribution.
///
/// This is the one place the project collaboration graph meets the declarative
/// contribution host: the host-owned document source, the validated action port
/// and the committed catalog epoch are wired here, and the app root places
/// [buildLayer] once in its tree. Nothing in the renderer reads a runtime, a
/// store or a controller, and no action reaches the native owner without
/// passing the port's origin, revision and identity checks.
library;

import 'package:flutter/widgets.dart';
import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_flutter/presentation_flutter.dart';

import '../../frontend/features/project_collaboration/ui/project_collaboration_strings.dart';

import '../../presentation/project_collaboration/project_collaboration_surface.dart';
import 'project_collaboration_session.dart';
import '../../projections/project_collaboration/project_collaboration_source.dart';
import 'extension_ui_composition.dart';

/// Contribution id the project collaboration view mounts under.
const String projectCollaborationContributionId =
    'licoup.project-collaboration/graph';

/// Resource name the contribution declares.
const String projectCollaborationResourceRef =
    'resource.licoup/project-collaboration';

/// Action name the contribution declares for its own dispatches.
const String projectCollaborationActionRef =
    'action.licoup/project-collaboration';

/// One mounted project collaboration surface.
final class ProjectCollaborationExtension {
  ProjectCollaborationExtension._({
    required this.source,
    required this.session,
    required this.composition,
  });

  /// Builds the surface over one composition.
  ///
  /// [owner] is the native owner of the graph actions. When it is null the
  /// contribution still mounts and renders admitted documents, but every
  /// action is refused with `project_collaboration_unavailable` instead of
  /// being answered by a stand-in.
  factory ProjectCollaborationExtension.mount({
    required ExtensionUiComposition composition,
    ProjectCollaborationActionOwner? owner,
    ProjectCollaborationDocumentSource? source,
  }) {
    final documentSource = source ?? ProjectCollaborationDocumentSource();
    final session = ProjectCollaborationSession(
      runtime: composition.runtime,
      source: documentSource,
      owner: owner,
      // The declarative host pins a mounted contribution to its own scope; the
      // port admits that scope plus this surface's own, and nothing else.
      admittedScopes: <ResourceScope>[
        ResourceScope('extension:$projectCollaborationContributionId'),
      ],
    );
    composition.bindings
      ..registerGraphResource(
        ExtensionUiGraphResourceBinding(
          resourceRef: projectCollaborationResourceRef,
          source: documentSource,
        ),
      )
      ..registerAction(projectCollaborationActionRef, session.actions);
    return ProjectCollaborationExtension._(
      source: documentSource,
      session: session,
      composition: composition,
    );
  }

  final ProjectCollaborationDocumentSource source;
  final ProjectCollaborationSession session;
  final ExtensionUiComposition composition;

  /// Starts observing; call after the first revision was seeded.
  void start() => session.start();

  /// The committed epoch that declares this contribution.
  ///
  /// A resource view mounts only when the shell compiles a renderer for the
  /// declared format, so an older shell preserves the contribution and refuses
  /// it locally instead of failing the epoch.
  static Map<String, Object?> epochDocument({int registryEpoch = 1}) =>
      <String, Object?>{
        'registryEpoch': registryEpoch,
        'servedProfiles': <Object?>[],
        'contributions': <Object?>[
          <String, Object?>{
            'schema': extensionUiContributionSchema,
            'id': projectCollaborationContributionId,
            'instanceId': 'licoup.project-collaboration',
            'generation': 1,
            'kind': 'resource-view',
            'title': 'Project collaboration',
            'resourceRef': projectCollaborationResourceRef,
            'actionRef': projectCollaborationActionRef,
            'resourceFormat': extensionUiGraphResourceFormat,
          },
        ],
      };

  /// Mounts the committed epoch that declares this contribution.
  void publishEpoch({int registryEpoch = 1}) =>
      composition.mountDocument(epochDocument(registryEpoch: registryEpoch));

  /// The one host surface this feature asks the app root to place.
  ///
  /// The layer installs the feature's text for the interface language, so the
  /// mounted graph surface speaks the application's language without the
  /// package knowing the catalog.
  Widget buildLayer({Key? key}) => Builder(
    key: key,
    builder: (context) => GraphViewStringsScope(
      strings: graphViewStringsFor(
        Localizations.localeOf(context).languageCode,
      ),
      child: composition.buildHost(emptyPlaceholder: const SizedBox.shrink()),
    ),
  );
}
