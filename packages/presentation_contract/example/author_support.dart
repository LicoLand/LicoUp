import 'package:presentation_contract/presentation_contract.dart';

/// Application-owned error context for a renderer-facing input.
///
/// The contract carries the stable scope and resource identity. An
/// application can add an operation name without making the contract depend
/// on a particular error taxonomy.
final class ExampleErrorAttribution {
  const ExampleErrorAttribution({
    required this.scope,
    required this.operation,
    this.resource,
  });

  final ResourceScope scope;
  final ResourceKey? resource;
  final String operation;
}

final class ExampleError {
  const ExampleError({required this.attribution, required this.message});

  final ExampleErrorAttribution attribution;
  final String message;
}

/// Fresh acceptance for one prepared member.
///
/// Atomic group installation comes from the contract's
/// [ConsistencyGroupInstall], so example support stays this small.
PreparationAcceptance<T> acceptMember<T>(PreparedResource<T> result) =>
    PreparationAcceptance<T>(request: result.request);
