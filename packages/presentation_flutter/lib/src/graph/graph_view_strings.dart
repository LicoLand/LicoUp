/// User-visible text of the project collaboration surface.
///
/// The package cannot read the application's string catalog, so the host
/// supplies this value through a [Localizations] override and the widget falls
/// back to English when no host text is installed. Nothing here carries an
/// internal code as its message: codes map to sentences, and exact values such
/// as a plan revision stay values.
library;

import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/widgets.dart';
import 'package:presentation_contract/presentation_contract.dart';

/// Localized text of the graph surface, the detail panel and the actions.
@immutable
final class GraphViewStrings {
  const GraphViewStrings({
    this.builderRole = 'Builder',
    this.reviewerRole = 'Reviewer',
    this.projectsTitle = 'Projects',
    this.roleFilterLabel = 'Role',
    this.allRoles = 'All roles',
    this.units = 'units',
    this.ready = 'ready',
    this.startable = 'startable',
    this.blocked = 'blocked',
    this.running = 'running',
    this.accepted = 'accepted',
    this.stale = 'stale',
    this.filterAll = 'All',
    this.filterFrontier = 'Frontier',
    this.filterAnomalies = 'Needs attention',
    this.zoomPercentLabel = 'Zoom {percent} percent',
    this.zoomIn = 'Zoom in',
    this.zoomOut = 'Zoom out',
    this.resetView = 'Reset view',
    this.inspectorTooltip = 'State inspector',
    this.listTooltip = 'Compact list',
    this.swimlanesTooltip = 'Swimlanes',
    this.windowNote =
        'Showing {shown} of {total} units; the totals above cover every unit.',
    this.emptyWindow = 'No unit is in the prepared window',
    this.emptyFiltered = 'No unit matches the current filter',
    this.gateShared = 'Shared gate · one run',
    this.gateRuns = 'Gate · {runs} runs',
    this.cannotStart = 'Cannot start: {reason}',
    this.startableNow = 'Can start',
    this.readyNotStartable = 'Ready, not startable',
    this.detailsTitle = 'Details',
    this.unitDetailTitle = 'Unit',
    this.inspectorTitle = 'State inspector',
    this.closeDetails = 'Close details',
    this.detailEmpty =
        'Select a unit to see its execution, acceptance and observation, why '
        'it cannot start, and the actions its owner published.',
    this.inspectorEmpty =
        'Select a unit to inspect its attempts, visits, events, errors and '
        'evidence references.',
    this.factExecution = 'Execution',
    this.factAcceptance = 'Acceptance',
    this.factObservation = 'Observation',
    this.factReady = 'Dependencies',
    this.factStartable = 'Start',
    this.whyCannotStart = 'Why it cannot start',
    this.affectedUnits = 'Affected units',
    this.noDependents = 'No dependent unit is declared',
    this.highlightAffected = 'Highlight {count} affected',
    this.sharedGate = 'Shared gate',
    this.gateSummary = '{runs} runs · {anchors} reference anchors',
    this.gateOneIdentity =
        'One gate: its reference anchors never add a second run.',
    this.attemptsTitle = 'Attempts',
    this.visitsTitle = 'Visits and joins',
    this.eventsTitle = 'Events',
    this.evidenceTitle = 'Evidence',
    this.noAttempts = 'No attempt recorded',
    this.noVisits = 'No visit recorded',
    this.noEvents = 'No event recorded',
    this.noEvidence = 'No evidence reference recorded',
    this.factAttempts = 'Attempts',
    this.factVisits = 'Visits and joins',
    this.factEvents = 'Events',
    this.factEvidence = 'Evidence references',
    this.factLastError = 'Last error',
    this.factLastEvent = 'Last event',
    this.actionsTitle = 'Actions',
    this.noActions = 'This unit publishes no action; it can only be observed.',
    this.typedInputs = 'Consumes and produces',
    this.noTypedRefs = 'No typed result reference is declared',
    this.consumes = 'consumes',
    this.produces = 'produces',
    this.actionObserve = 'Observe',
    this.actionManage = 'Manage',
    this.actionTakeover = 'Take over',
    this.actionPause = 'Pause',
    this.actionCancel = 'Cancel',
    this.waitingForReceipt = 'Waiting for owner',
    this.takeoverTitle = 'Take over this unit',
    this.takeoverBody =
        'Scope: this unit and the visits that belong to it. If an old writer '
        'still holds it, the owner refuses the request and the reason is shown '
        'here. Nothing changes until the owner answers.',
    this.takeoverConfirm = 'Request takeover',
    this.cancel = 'Cancel',
    this.listStartable = 'Can start',
    this.listReady = 'Ready',
    this.listBlocked = 'Blocked',
    this.unavailableTitle = 'Project collaboration is unavailable',
    this.unavailableLoading = 'Loading the project graph',
    this.unavailableSource = 'The project source is no longer available',
    this.unavailableBinding = 'This build has no project source bound',
    this.unavailablePreparation = 'The project graph could not be prepared',
    this.unavailableLayout = 'The project layout could not be prepared',
    this.unavailableUnknown = 'The project graph is unavailable',
    this.attemptQueued = 'Queued',
    this.attemptRunning = 'Running',
    this.attemptSucceeded = 'Succeeded',
    this.attemptFailed = 'Failed',
    this.attemptCancelled = 'Cancelled',
    this.attemptSuperseded = 'Superseded',
    this.executionNotStarted = 'Not started',
    this.executionClaimed = 'Claimed',
    this.executionRunning = 'Running',
    this.executionSucceeded = 'Succeeded',
    this.executionFailed = 'Failed',
    this.executionCancelled = 'Cancelled',
    this.acceptancePending = 'Pending',
    this.acceptanceReviewing = 'In review',
    this.acceptanceAccepted = 'Accepted',
    this.acceptanceRejected = 'Rejected',
    this.acceptanceSuperseded = 'Superseded',
    this.observationFresh = 'Fresh',
    this.observationStale = 'Expired',
    this.observationUnknown = 'Unknown',
    this.blockerDependencyMissing = 'a dependency is not satisfied',
    this.blockerResultMissing = 'a required result is missing',
    this.blockerVisitMissing = 'a required visit is missing',
    this.blockerNotMaterialized = 'the inputs are not materialized yet',
    this.blockerAuthorityMissing = 'the original authority is missing',
    this.blockerRouteUnavailable = 'no route can run it',
    this.blockerBudgetMissing = 'the budget is exhausted',
    this.blockerCapacityMissing = 'no capacity is free',
    this.blockerConflictingWriter = 'another writer still holds it',
    this.blockerObservationStale = 'the last observation expired',
    this.blockerManagedByOther = 'another session manages it',
    this.blockerPaused = 'it is paused',
    this.blockerUnknown = 'the owner reported an unknown reason',
    this.receiptAccepted = 'The owner accepted the request',
    this.receiptPreviewed = 'The owner prepared a preview',
    this.receiptStaleRevision = 'The plan changed; the request was not applied',
    this.receiptConflictingWriter = 'Another writer still holds this unit',
    this.receiptAuthorityMissing = 'The original authority is missing',
    this.receiptUnknownNode = 'The unit is no longer in the plan',
    this.receiptDuplicate = 'The same request is already in flight',
    this.receiptNoPreview = 'There is no preview to commit',
    this.receiptOriginMismatch = 'The request came from an unknown surface',
    this.receiptUnavailable = 'The native project service is not connected',
    this.receiptUnknown = 'The owner refused the request',
    this.insertUnit = 'Insert unit',
    this.insertTitle = 'Insert unit',
    this.insertUnitRef = 'Unit reference',
    this.insertUnitRefHelp = 'A bounded reference the owner resolves.',
    this.insertLane = 'Lane',
    this.insertRole = 'Role',
    this.insertNote =
        'Nothing changes until the preview is committed at exactly its '
        'revision.',
    this.insertPreview = 'Preview impact',
    this.insertImpactTitle = 'Previewed impact',
    this.insertImpactNone = 'No existing unit is moved or re-gated.',
    this.insertImpactAffected = '{count} units would be affected',
    this.insertCommit = 'Commit revision {revision}',
    this.insertDiscard = 'Discard preview',
    this.noReceiptYet = 'No request has been answered yet',
    this.receiptLine = '{message} · plan {revision}',
    this.planRevision = 'Plan {revision}',
  });

  final String builderRole;
  final String reviewerRole;
  String roleName(String id) => switch (id.split('/').last) {
    'builder' => builderRole,
    'reviewer' => reviewerRole,
    final name => name,
  };
  final String projectsTitle;
  final String roleFilterLabel;
  final String allRoles;
  final String units;
  final String ready;
  final String startable;
  final String blocked;
  final String running;
  final String accepted;
  final String stale;
  final String filterAll;
  final String filterFrontier;
  final String filterAnomalies;
  final String zoomPercentLabel;
  final String zoomIn;
  final String zoomOut;
  final String resetView;
  final String inspectorTooltip;
  final String listTooltip;
  final String swimlanesTooltip;
  final String windowNote;
  final String emptyWindow;
  final String emptyFiltered;
  final String gateShared;
  final String gateRuns;
  final String cannotStart;
  final String startableNow;
  final String readyNotStartable;
  final String detailsTitle;
  final String unitDetailTitle;
  final String inspectorTitle;
  final String closeDetails;
  final String detailEmpty;
  final String inspectorEmpty;
  final String factExecution;
  final String factAcceptance;
  final String factObservation;
  final String factReady;
  final String factStartable;
  final String whyCannotStart;
  final String affectedUnits;
  final String noDependents;
  final String highlightAffected;
  final String sharedGate;
  final String gateSummary;
  final String gateOneIdentity;
  final String attemptsTitle;
  final String visitsTitle;
  final String eventsTitle;
  final String evidenceTitle;
  final String noAttempts;
  final String noVisits;
  final String noEvents;
  final String noEvidence;
  final String factAttempts;
  final String factVisits;
  final String factEvents;
  final String factEvidence;
  final String factLastError;
  final String factLastEvent;
  final String actionsTitle;
  final String noActions;
  final String typedInputs;
  final String noTypedRefs;
  final String consumes;
  final String produces;
  final String actionObserve;
  final String actionManage;
  final String actionTakeover;
  final String actionPause;
  final String actionCancel;
  final String waitingForReceipt;
  final String takeoverTitle;
  final String takeoverBody;
  final String takeoverConfirm;
  final String cancel;
  final String listStartable;
  final String listReady;
  final String listBlocked;
  final String unavailableTitle;
  final String unavailableLoading;
  final String unavailableSource;
  final String unavailableBinding;
  final String unavailablePreparation;
  final String unavailableLayout;
  final String unavailableUnknown;
  final String attemptQueued;
  final String attemptRunning;
  final String attemptSucceeded;
  final String attemptFailed;
  final String attemptCancelled;
  final String attemptSuperseded;
  final String executionNotStarted;
  final String executionClaimed;
  final String executionRunning;
  final String executionSucceeded;
  final String executionFailed;
  final String executionCancelled;
  final String acceptancePending;
  final String acceptanceReviewing;
  final String acceptanceAccepted;
  final String acceptanceRejected;
  final String acceptanceSuperseded;
  final String observationFresh;
  final String observationStale;
  final String observationUnknown;
  final String blockerDependencyMissing;
  final String blockerResultMissing;
  final String blockerVisitMissing;
  final String blockerNotMaterialized;
  final String blockerAuthorityMissing;
  final String blockerRouteUnavailable;
  final String blockerBudgetMissing;
  final String blockerCapacityMissing;
  final String blockerConflictingWriter;
  final String blockerObservationStale;
  final String blockerManagedByOther;
  final String blockerPaused;
  final String blockerUnknown;
  final String receiptAccepted;
  final String receiptPreviewed;
  final String receiptStaleRevision;
  final String receiptConflictingWriter;
  final String receiptAuthorityMissing;
  final String receiptUnknownNode;
  final String receiptDuplicate;
  final String receiptNoPreview;
  final String receiptOriginMismatch;
  final String receiptUnavailable;
  final String receiptUnknown;
  final String insertUnit;
  final String insertTitle;
  final String insertUnitRef;
  final String insertUnitRefHelp;
  final String insertLane;
  final String insertRole;
  final String insertNote;
  final String insertPreview;
  final String insertImpactTitle;
  final String insertImpactNone;
  final String insertImpactAffected;
  final String insertCommit;
  final String insertDiscard;
  final String noReceiptYet;
  final String receiptLine;
  final String planRevision;

  /// The strings the host installed, or the English defaults.
  static GraphViewStrings of(BuildContext context) =>
      Localizations.of<GraphViewStrings>(context, GraphViewStrings) ??
      const GraphViewStrings();

  /// Fills `{name}` placeholders with exact values.
  static String fill(String template, Map<String, String> values) {
    var result = template;
    for (final entry in values.entries) {
      result = result.replaceAll('{${entry.key}}', entry.value);
    }
    return result;
  }

  /// The sentence for one execution dimension.
  String execution(GraphExecutionState? state) => switch (state) {
    GraphExecutionState.notStarted => executionNotStarted,
    GraphExecutionState.claimed => executionClaimed,
    GraphExecutionState.running => executionRunning,
    GraphExecutionState.succeeded => executionSucceeded,
    GraphExecutionState.failed => executionFailed,
    GraphExecutionState.cancelled => executionCancelled,
    null => observationUnknown,
  };

  /// The sentence for one acceptance dimension.
  String acceptance(GraphAcceptanceState? state) => switch (state) {
    GraphAcceptanceState.pending => acceptancePending,
    GraphAcceptanceState.reviewing => acceptanceReviewing,
    GraphAcceptanceState.accepted => acceptanceAccepted,
    GraphAcceptanceState.rejected => acceptanceRejected,
    GraphAcceptanceState.superseded => acceptanceSuperseded,
    null => observationUnknown,
  };

  /// The sentence for one observation dimension.
  String observation(GraphObservationState? state) => switch (state) {
    GraphObservationState.fresh => observationFresh,
    GraphObservationState.stale => observationStale,
    GraphObservationState.unknown => observationUnknown,
    null => observationUnknown,
  };

  /// The sentence for one native blocker reason.
  String blocker(GraphBlockerCode? code) => switch (code) {
    GraphBlockerCode.dependencyMissing => blockerDependencyMissing,
    GraphBlockerCode.resultMissing => blockerResultMissing,
    GraphBlockerCode.visitMissing => blockerVisitMissing,
    GraphBlockerCode.notMaterialized => blockerNotMaterialized,
    GraphBlockerCode.authorityMissing => blockerAuthorityMissing,
    GraphBlockerCode.routeUnavailable => blockerRouteUnavailable,
    GraphBlockerCode.budgetMissing => blockerBudgetMissing,
    GraphBlockerCode.capacityMissing => blockerCapacityMissing,
    GraphBlockerCode.conflictingWriter => blockerConflictingWriter,
    GraphBlockerCode.observationStale => blockerObservationStale,
    GraphBlockerCode.managedByOther => blockerManagedByOther,
    GraphBlockerCode.paused => blockerPaused,
    GraphBlockerCode.unknown => blockerUnknown,
    null => blockerUnknown,
  };

  /// The sentence for one action receipt outcome.
  String receipt(String code) => switch (code) {
    'accepted' => receiptAccepted,
    'previewed' => receiptPreviewed,
    'stale_revision' => receiptStaleRevision,
    'conflicting_writer' => receiptConflictingWriter,
    'authority_missing' => receiptAuthorityMissing,
    'unknown_node' => receiptUnknownNode,
    'duplicate_action' => receiptDuplicate,
    'no_preview' => receiptNoPreview,
    'origin_mismatch' => receiptOriginMismatch,
    'project_collaboration_unavailable' => receiptUnavailable,
    _ => receiptUnknown,
  };

  /// The sentence for one unavailable reason.
  String unavailable(String? reason) => switch (reason) {
    null => unavailableLoading,
    'loading' => unavailableLoading,
    'source_unavailable' => unavailableSource,
    'binding_unavailable' => unavailableBinding,
    'preparation_unavailable' => unavailablePreparation,
    'layout_unavailable' => unavailableLayout,
    _ => unavailableUnknown,
  };

  /// The sentence for one attempt state.
  String attempt(String state) => switch (state) {
    'queued' => attemptQueued,
    'running' => attemptRunning,
    'succeeded' => attemptSucceeded,
    'failed' => attemptFailed,
    'cancelled' => attemptCancelled,
    'superseded' => attemptSuperseded,
    _ => observationUnknown,
  };

  /// The accessible zoom label.
  String zoomPercent(int percent) =>
      fill(zoomPercentLabel, <String, String>{'percent': '$percent'});

  /// The label of one declared action reference.
  String action(String actionRef) => switch (actionRef) {
    'licoup.action/unit-observe' => actionObserve,
    'licoup.action/unit-manage' => actionManage,
    'licoup.action/unit-takeover' => actionTakeover,
    'licoup.action/unit-pause' => actionPause,
    'licoup.action/unit-cancel' => actionCancel,
    _ => actionRef,
  };
}

/// Installs [GraphViewStrings] for the subtree it wraps.
class GraphViewStringsScope extends StatelessWidget {
  const GraphViewStringsScope({
    super.key,
    required this.strings,
    required this.child,
  });

  final GraphViewStrings strings;
  final Widget child;

  @override
  Widget build(BuildContext context) => Localizations.override(
    context: context,
    delegates: <LocalizationsDelegate<Object>>[
      _GraphViewStringsDelegate(strings),
    ],
    child: child,
  );
}

final class _GraphViewStringsDelegate
    extends LocalizationsDelegate<GraphViewStrings> {
  const _GraphViewStringsDelegate(this.strings);

  final GraphViewStrings strings;

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<GraphViewStrings> load(Locale locale) =>
      SynchronousFuture<GraphViewStrings>(strings);

  @override
  bool shouldReload(_GraphViewStringsDelegate old) => old.strings != strings;
}

/// A delegate that resolves the host text for one locale.
///
/// The application registers this so the graph surface follows the interface
/// language without the package knowing the catalog.
class GraphViewStringsDelegate extends LocalizationsDelegate<GraphViewStrings> {
  const GraphViewStringsDelegate({required this.forLanguage});

  /// Builds the host text for one language code (`zh`, `en`, ...).
  final GraphViewStrings Function(String languageCode) forLanguage;

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<GraphViewStrings> load(Locale locale) =>
      SynchronousFuture<GraphViewStrings>(forLanguage(locale.languageCode));

  @override
  bool shouldReload(GraphViewStringsDelegate old) =>
      old.forLanguage != forLanguage;
}
