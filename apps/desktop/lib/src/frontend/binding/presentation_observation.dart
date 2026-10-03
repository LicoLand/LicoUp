import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/frontend/binding/projection_telemetry_scope.dart';

/// Why a presentation phase stopped being observable for a trace.
///
/// A phase that never happened and a phase that could not be observed are
/// different facts: the caller chooses the truthful reason for the phase the
/// trace actually reached, and no timer guesses it.
enum CausalTelemetryUnavailableReason {
  /// No sample was taken at all.
  noSamples,

  /// A projection was never emitted for the trace.
  projectionNotObserved,

  /// A rendered frame was never observed for the trace.
  frameNotObserved,

  /// The bounded pending window evicted the trace under pressure.
  capacityEvicted,
}

/// The presentation observation owner a composition installs, when any.
///
/// This is the seam between the composition root and whatever wants to watch
/// the presentation plane. It joins the phases one ordinary interaction passes
/// through: a renderer intent begins a trace, a projection is emitted and
/// received by the renderer that rebuilds for it, and the frame that consumed
/// the projection reports its build and raster phase.
///
/// Installation is a composition decision and it is optional by design. When a
/// composition installs no owner, no source is traced, no receipt is observed
/// and no frame is sampled, so an unobserved client is exactly the client that
/// existed before this seam. An installed owner is the single owner of the
/// phase facts it receives; implementations retain them in a bounded window and
/// never write them anywhere else.
///
/// Implementations must stay process-local: a trace identifier and timings
/// never leave the process and are never attached to a native or network
/// request.
abstract interface class PresentationObservation
    implements ProjectionReceiptObserver {
  /// Begins a trace for an interaction the renderer is about to perform.
  TraceContext beginRendererIntent();

  /// Records that a projection was emitted for [trace].
  ///
  /// A null [trace] means the update originated in the runtime rather than in
  /// the renderer; the owner then begins its own trace.
  TraceContext projectionEmitted({TraceContext? trace});

  /// Records that Flutter received the projection carried by [trace].
  void flutterReceived(TraceContext trace);

  /// Releases a trace whose projection or frame can no longer be observed.
  ///
  /// Callers choose the truthful phase-specific reason.
  void discardTrace(TraceContext trace, CausalTelemetryUnavailableReason reason);

  /// Releases a delivered trace only when no renderer observer accepted it.
  void discardIfNotReceived(
    TraceContext trace,
    CausalTelemetryUnavailableReason reason,
  );

  /// Attaches frame phase observation to [binding], when one is supported.
  void attachFrameObservation(WidgetsBinding binding);

  /// Stops observing and releases every retained phase fact.
  void dispose();
}
