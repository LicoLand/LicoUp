import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/state/application_signal.dart';

typedef RendererIntentTraceFactory = TraceContext Function();

/// Retains an explicitly propagated trace or starts one at the renderer's
/// semantic intent boundary when causal telemetry is enabled.
TraceContext? resolveRendererIntentTrace(
  TraceContext? trace,
  RendererIntentTraceFactory? beginRendererIntent,
) => trace ?? beginRendererIntent?.call();

ApplicationCause? applicationCauseForTrace(TraceContext? trace) =>
    trace?.traceId == null ? null : ApplicationCause(traceId: trace!.traceId);
