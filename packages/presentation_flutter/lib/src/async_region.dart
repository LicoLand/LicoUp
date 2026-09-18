import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

/// Visual mapping callback when asynchronous data is ready.
typedef AsyncRegionDataRenderer<Inputs, Actions> =
    Widget Function(BuildContext context, Inputs data, Actions actions);

/// Visual mapping callback during initial load or when loading without valid data.
typedef AsyncRegionLoadingRenderer<Actions> =
    Widget Function(BuildContext context, Actions actions);

/// Visual mapping callback when an asynchronous error occurs.
typedef AsyncRegionErrorRenderer<Actions> =
    Widget Function(
      BuildContext context,
      Object error,
      StackTrace? stackTrace,
      Actions actions,
    );

/// Consumer widget that maps a Riverpod [AsyncValue] source into visual states:
/// [data], [loading], and [error].
///
/// **Revocation Guarantee:**
/// When an existing valid source is refreshed, previous data is retained by default
/// so the screen does not flicker. However, if the source is revoked (indicated by
/// [isRevoked] returning true, or an unauthenticated/revoked error), the old frame is
/// IMMEDIATELY discarded so that revocation is never delayed by retaining a stale frame.
class AsyncRegion<Inputs, Actions> extends ConsumerWidget {
  const AsyncRegion({
    super.key,
    required this.source,
    required this.actions,
    required this.data,
    this.loading,
    this.error,
    this.revoked,
    this.isRevoked,
    this.retainPreviousDataOnRefresh = true,
  });

  /// The Riverpod listenable yielding an [AsyncValue] containing [Inputs].
  final ProviderListenable<AsyncValue<Inputs>> source;

  /// Typed actions passed to render callbacks.
  final Actions actions;

  /// Visual mapping when data is available and not revoked.
  final AsyncRegionDataRenderer<Inputs, Actions> data;

  /// Visual mapping while loading without valid data.
  final AsyncRegionLoadingRenderer<Actions>? loading;

  /// Visual mapping when an error occurs.
  final AsyncRegionErrorRenderer<Actions>? error;

  /// Visual mapping when data has been revoked or invalidated.
  ///
  /// If omitted, falls back to [loading] or the default loading indicator.
  final AsyncRegionLoadingRenderer<Actions>? revoked;

  /// Predicate to determine whether a given [Inputs] snapshot is revoked or
  /// invalidated (e.g. session logout, scope switch, permission revoked).
  ///
  /// When true, any old frame is discarded immediately.
  final bool Function(Inputs inputs)? isRevoked;

  /// Whether to retain previous data while an active source is refreshing.
  ///
  /// Defaults to true for smooth UI updates. Revocation ([isRevoked]) and
  /// unhandled errors take precedence and clear the old frame immediately.
  final bool retainPreviousDataOnRefresh;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncValue = ref.watch(source);

    // 1. Error state
    if (asyncValue.hasError) {
      // If previous value was revoked, do not retain old data.
      final previous = asyncValue.hasValue ? asyncValue.requireValue : null;
      if (previous != null && isRevoked != null && isRevoked!(previous)) {
        return revoked?.call(context, actions) ??
            loading?.call(context, actions) ??
            _defaultLoading();
      }
      if (error != null) {
        return error!(
          context,
          asyncValue.error!,
          asyncValue.stackTrace,
          actions,
        );
      }
      return _defaultError(asyncValue.error!);
    }

    // 2. Loading state
    if (asyncValue.isLoading) {
      if (retainPreviousDataOnRefresh && asyncValue.hasValue) {
        final previous = asyncValue.requireValue;
        if (isRevoked != null && isRevoked!(previous)) {
          // Revoked: must NOT retain old frame!
          return revoked?.call(context, actions) ??
              loading?.call(context, actions) ??
              _defaultLoading();
        }
        return data(context, previous, actions);
      }
      return loading?.call(context, actions) ?? _defaultLoading();
    }

    // 3. Data state
    if (asyncValue.hasValue) {
      final value = asyncValue.requireValue;
      if (isRevoked != null && isRevoked!(value)) {
        return revoked?.call(context, actions) ??
            loading?.call(context, actions) ??
            _defaultLoading();
      }
      return data(context, value, actions);
    }

    return loading?.call(context, actions) ?? _defaultLoading();
  }

  static Widget _defaultLoading() => const Center(
    child: SizedBox.square(
      dimension: 24,
      child: CircularProgressIndicator(strokeWidth: 2),
    ),
  );

  static Widget _defaultError(Object error) => Center(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Text(
        'Error: $error',
        textAlign: TextAlign.center,
        style: const TextStyle(color: Color(0xFFD32F2F)),
      ),
    ),
  );
}
