/// Harness that mounts the project collaboration surface for the interaction
/// machine.
///
/// The surface is the real feature: the feature page, the prepared graph view,
/// the runtime's preparation pipeline and the validated action port. The
/// harness holds the application-scope lease on the source, exactly as the app
/// composition does, so the two native events the interface does not own
/// (authority withdrawal, reconnect) go through the runtime and an application
/// re-read instead of through a UI control that pretends to have that power.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_flutter/presentation_flutter.dart';
import 'package:presentation_runtime/presentation_runtime.dart';
import 'package:licoup/src/composition/extensions/extension_ui_composition.dart';
import 'package:licoup/src/frontend/features/project_collaboration/ui/project_collaboration_page.dart';
import 'package:licoup/src/frontend/features/project_collaboration/ui/project_collaboration_strings.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/composition/extensions/project_collaboration_session.dart';
import 'package:licoup/src/projections/project_collaboration/project_collaboration_source.dart';

import '../project_collaboration/project_collaboration_scenario.dart';

/// One mounted project collaboration surface plus its native stand-in.
final class ProjectCollaborationHarness {
  ProjectCollaborationHarness._({
    required this.runtime,
    required this.composition,
    required this.owner,
    required this.source,
    required this.wide,
    required SourceOwnership<GraphDocumentUpdate> ownership,
  }) : _ownership = ownership,
       _sessions = ValueNotifier<ProjectCollaborationSession>(
         _startSession(composition, owner, source),
       );

  late final PresentationRuntime runtime;
  late final ExtensionUiComposition composition;
  late final SyntheticProjectCollaborationOwner owner;
  late final ProjectCollaborationDocumentSource source;
  final SourceOwnership<GraphDocumentUpdate> _ownership;
  final ValueNotifier<ProjectCollaborationSession> _sessions;
  int _incarnation = 1;

  /// Whether this harness runs the frozen budget scale.
  final bool wide;

  static ProjectCollaborationSession _startSession(
    ExtensionUiComposition composition,
    SyntheticProjectCollaborationOwner owner,
    ProjectCollaborationDocumentSource source,
  ) => ProjectCollaborationSession(
    runtime: composition.runtime,
    source: source,
    owner: owner,
  )..start();

  /// Builds the harness over a fresh runtime and composition.
  ///
  /// [wide] seeds the frozen budget scale (8 projects, 1000 nodes, 2000 edges)
  /// for the performance profile; the default seed is the three-project
  /// scenario the functional walk uses.
  static ProjectCollaborationHarness create({bool wide = false}) {
    final runtime = PresentationRuntime();
    final composition = ExtensionUiComposition(runtime: runtime);
    final source = ProjectCollaborationDocumentSource()
      ..seed(
        GraphResourceValue.fromJson(
          wide ? wideScaleDocumentJson() : threeProjectDocumentJson(),
        ),
      );
    // The application scope holds the source session, so a reconnect is an
    // application read rather than a new claim on the same resource name.
    final ownership = runtime.own(source);
    late final SyntheticProjectCollaborationOwner owner;
    owner = SyntheticProjectCollaborationOwner(
      currentRevision: () =>
          runtime
              .current(graphDocumentFieldGroupFor(source.fieldGroup.resource))
              ?.value
              .document
              .planRevision ??
          0,
      takeoverRefusal: 'conflicting_writer',
    );
    return ProjectCollaborationHarness._(
      runtime: runtime,
      composition: composition,
      owner: owner,
      source: source,
      wide: wide,
      ownership: ownership,
    );
  }

  ProjectCollaborationSession get session => _sessions.value;

  /// Wraps the production shell with the collaboration surface.
  ///
  /// The application root owns the destination and the contribution host
  /// (`composition/project_collaboration_root.dart`, FI); this harness mounts
  /// the same feature page in the same theme and localization context so the
  /// machine drives the real page under the real interface language. The
  /// production app beneath is the shell fixture, so the surface renders in the
  /// application's own window rather than in a second application.
  Widget wrap(Widget app) => Directionality(
    textDirection: TextDirection.ltr,
    child: Stack(
      fit: StackFit.expand,
      children: [
        app,
        MaterialApp(
          debugShowCheckedModeBanner: false,
          locale: const Locale('zh'),
          supportedLocales: LicoStrings.supportedLocales,
          localizationsDelegates: const <LocalizationsDelegate<Object>>[
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          theme: buildLicoTheme(platformBrightness: Brightness.dark),
          builder: (context, child) => GraphViewStringsScope(
            strings: graphViewStringsFor(
              Localizations.localeOf(context).languageCode,
            ),
            child: child!,
          ),
          home: ValueListenableBuilder<ProjectCollaborationSession>(
            valueListenable: _sessions,
            builder: (context, session, _) => Scaffold(
              // A replaced incarnation starts a fresh interface state: a
              // collapse, filter or selection from a plan that no longer exists
              // must not be inherited by the next one.
              body: ProjectCollaborationPage(
                key: ValueKey<ProjectCollaborationSession>(session),
                surface: session,
              ),
            ),
          ),
        ),
      ],
    ),
  );

  /// The native owner withdraws authority over the resource.
  void revoke() {
    runtime.revoke(
      ResourceKey(
        scope: projectCollaborationGraphScope,
        stableKey: projectCollaborationGraphKey,
      ),
    );
  }

  /// The application reads the source again after the withdrawal.
  ///
  /// The producer publishes a fresh incarnation first; the re-read then admits
  /// it for whoever is looking, which is how a reconnect restores the surface.
  Future<void> reconnect() async {
    final previous = session;
    _incarnation++;
    source.reopen(
      document: GraphResourceValue.fromJson(
        wide
            ? wideScaleDocumentJson(planRevision: 3)
            : threeProjectDocumentJson(planRevision: 3),
      ),
      epochId: 'project-collaboration-$_incarnation',
    );
    final next = _startSession(composition, owner, source);
    _sessions.value = next;
    previous.dispose();
    await _ownership.reconnect();
  }

  /// Releases the surface. The worker pool's shutdown handshake needs real
  /// time, so callers drain with real waits between frames after this returns
  /// (the binding refuses to end a test with pending timers).
  Future<void> dispose() async {
    _sessions.value.dispose();
    unawaited(_ownership.release());
    unawaited(composition.dispose());
    runtime.dispose();
  }
}
