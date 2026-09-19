import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'author_support.dart';

final class ListItem {
  const ListItem({required this.stableKey, required this.title});

  final String stableKey;
  final String title;
}

/// List inputs can retain useful stale rows while attributing a source error.
final class FilteredListInputs {
  FilteredListInputs({
    required this.scope,
    required this.query,
    required Iterable<ListItem> items,
    this.error,
  }) : items = List<ListItem>.unmodifiable(items);

  final ResourceScope scope;
  final String query;
  final List<ListItem> items;
  final ExampleError? error;
}

sealed class FilteredListAction {
  const FilteredListAction();
}

final class SelectListItem extends FilteredListAction {
  const SelectListItem(this.stableKey);

  final String stableKey;
}

final class RefreshList extends FilteredListAction {
  const RefreshList();
}

final class FilteredListActions {
  const FilteredListActions({
    required this.origin,
    required this.select,
    required this.refresh,
  });

  final ActionOrigin origin;
  final FutureOr<void> Function(String stableKey) select;
  final FutureOr<void> Function() refresh;
}

final class ListActionLog {
  String? selectedKey;
  int refreshCount = 0;
}

final class ListExampleResult {
  const ListExampleResult({
    required this.inputs,
    required this.actions,
    required this.actionLog,
  });

  final FilteredListInputs inputs;
  final FilteredListActions actions;
  final ListActionLog actionLog;
}

ListExampleResult buildListExample() {
  final scope = const ResourceScope('list:synthetic');
  final resource = ResourceKey(scope: scope, stableKey: 'items');
  final error = ExampleError(
    attribution: ExampleErrorAttribution(
      scope: scope,
      resource: resource,
      operation: 'list.read',
    ),
    message: 'The next page is not available yet.',
  );
  final inputs = FilteredListInputs(
    scope: scope,
    query: 'ap',
    items: const <ListItem>[
      ListItem(stableKey: 'apple', title: 'Apple'),
      ListItem(stableKey: 'apricot', title: 'Apricot'),
    ],
    error: error,
  );

  final actionLog = ListActionLog();
  final callback = CallbackActions<FilteredListAction>(
    origin: ActionOrigin(scope: scope, resource: resource),
    onDispatch: (action, origin) {
      if (origin.scope != inputs.scope) {
        throw StateError('list action crossed its originating scope');
      }
      switch (action) {
        case SelectListItem(:final stableKey):
          actionLog.selectedKey = stableKey;
        case RefreshList():
          actionLog.refreshCount++;
      }
    },
  );
  final actions = FilteredListActions(
    origin: callback.origin,
    select: (stableKey) => callback.dispatch(SelectListItem(stableKey)),
    refresh: () => callback.dispatch(const RefreshList()),
  );

  return ListExampleResult(
    inputs: inputs,
    actions: actions,
    actionLog: actionLog,
  );
}

void main() {
  final result = buildListExample();
  result.actions.select(result.inputs.items.first.stableKey);
  result.actions.refresh();

  if (result.actionLog.selectedKey != 'apple' ||
      result.actionLog.refreshCount != 1) {
    throw StateError('typed list actions were not delivered');
  }
  final error = result.inputs.error;
  if (error == null ||
      error.attribution.scope != result.inputs.scope ||
      error.attribution.resource == null) {
    throw StateError('list error lost its scope or resource attribution');
  }

  print('list query: ${result.inputs.query}');
  print('visible rows: ${result.inputs.items.length}');
  print('error operation: ${error.attribution.operation}');
}
