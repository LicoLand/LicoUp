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

/// A deliberately small example installer.
///
/// A consistency group is staged by field group and becomes visible only
/// after every changed member has passed its request-generation and lifecycle
/// acceptance check. This is an author example, not a second runtime.
final class AtomicExampleInstaller<T> {
  AtomicExampleInstaller(this.group);

  final ConsistencyGroup group;
  Map<ResourceFieldGroup<T>, PreparedResource<T>> _staged =
      <ResourceFieldGroup<T>, PreparedResource<T>>{};
  Map<ResourceFieldGroup<T>, PreparedResource<T>> _installed =
      <ResourceFieldGroup<T>, PreparedResource<T>>{};

  ConsistencyGroupId? lastInstalledGroup;

  Map<ResourceFieldGroup<T>, PreparedResource<T>> get installed =>
      Map<ResourceFieldGroup<T>, PreparedResource<T>>.unmodifiable(_installed);

  bool install(
    PreparedResource<T> result,
    PreparationAcceptance<T> acceptance,
  ) {
    if (!acceptance.canInstall(result)) return false;

    final resultGroup = result.request.consistencyGroup;
    if (resultGroup != group ||
        !group.changed.any(
          (changed) => changed.matches(result.request.resource),
        )) {
      return false;
    }

    final staged = <ResourceFieldGroup<T>, PreparedResource<T>>{
      ..._staged,
      result.request.resource: result,
    };
    if (!_containsEveryChangedField(staged)) {
      _staged = staged;
      return false;
    }

    _installed = staged;
    _staged = <ResourceFieldGroup<T>, PreparedResource<T>>{};
    lastInstalledGroup = group.id;
    return true;
  }

  bool _containsEveryChangedField(
    Map<ResourceFieldGroup<T>, PreparedResource<T>> staged,
  ) {
    return group.changed.every((changed) => staged.keys.any(changed.matches));
  }
}
