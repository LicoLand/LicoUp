import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'author_support.dart';

final class ListItem {
  const ListItem({required this.stableKey, required this.title});

  final String stableKey;
  final String title;
}

/// Prepared payload of one block, as a worker would hand it to a view.
final class ListFragment {
  const ListFragment({required this.rows});

  final List<String> rows;
}

/// Ordinary data for the host table primitive.
final class FilteredListTableInputs {
  const FilteredListTableInputs({required this.columns, required this.rows});

  final List<String> columns;
  final List<List<String>> rows;
}

/// List inputs can retain useful stale rows while attributing a source error.
final class FilteredListInputs {
  FilteredListInputs({
    required this.scope,
    required this.query,
    required Iterable<ListItem> items,
    required this.prepared,
    this.error,
  }) : items = List<ListItem>.unmodifiable(items);

  final ResourceScope scope;
  final String query;
  final List<ListItem> items;
  final PreparedValue<ListFragment> prepared;
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
    required this.table,
    required this.unresolvedPrefixLength,
    required this.resolvedPrefixLength,
    required this.queryIsDeclaredInput,
    required this.actionLog,
  });

  final FilteredListInputs inputs;
  final FilteredListActions actions;
  final DeclarativeInput<FilteredListTableInputs, FilteredListAction> table;

  /// Frozen blocks while one cross-block reference is still unresolved.
  final int unresolvedPrefixLength;

  /// Frozen blocks once the referenced block is sealed in the same revision.
  final int resolvedPrefixLength;

  final bool queryIsDeclaredInput;
  final ListActionLog actionLog;
}

ListExampleResult buildListExample() {
  final scope = const ResourceScope('list:synthetic');
  final resource = ResourceKey(scope: scope, stableKey: 'items');
  final queryFields = ResourceFieldGroup<String>(
    resource: resource,
    name: 'query',
  );
  final position = const SourcePosition(
    epoch: SourceEpoch('list-epoch'),
    version: SourceVersion(1),
  );
  final parserVersion = const ParserVersion('list-markdown@1');
  final syntaxConfig = SyntaxConfig(revision: 'list-syntax@1');

  // A row block that depends on a summary block: a link definition, a header,
  // or another message can make one block's output depend on a block elsewhere.
  final summaryReference = BlockReference(
    resource: resource,
    blockId: const BlockId('summary'),
  );
  SourceBlock block({
    required String id,
    required bool sealed,
    Iterable<BlockReference> references = const <BlockReference>[],
  }) => SourceBlock(
    id: BlockId(id),
    version: const BlockVersion(1),
    text: SourceTextReference(
      resource: resource,
      position: position,
      range: const SourceTextRange(start: 0, end: 8),
    ),
    isSealed: sealed,
    references: references,
  );
  PreparedValue<ListFragment> preparedFor(Iterable<SourceBlock> blocks) {
    final content = ContentRevision(
      resource: resource,
      position: position,
      blocks: blocks,
    );
    return PreparedValue<ListFragment>.fromBlocks(
      key: PreparationKey(
        parserVersion: parserVersion,
        syntaxConfig: syntaxConfig,
        content: content,
      ),
      blocks: <PreparedBlock<ListFragment>>[
        for (final source in content.blocks)
          PreparedBlock<ListFragment>(
            block: source,
            value: ListFragment(rows: <String>[source.id.value]),
          ),
      ],
      referencedInputs: <PreparedInputReference>[
        PreparedInputReference(
          resource: resource,
          name: 'query',
          position: position,
        ),
      ],
    );
  }

  // The referenced summary block is still open, so the sealed row block stays
  // in the mutable tail instead of freezing a value that can still change.
  final pending = preparedFor(<SourceBlock>[
    block(
      id: 'rows',
      sealed: true,
      references: <BlockReference>[summaryReference],
    ),
    block(id: 'summary', sealed: false),
  ]);

  // The same row block freezes as soon as the referenced block is sealed here,
  // without re-reading the blocks that did not change.
  final settled = preparedFor(<SourceBlock>[
    block(
      id: 'rows',
      sealed: true,
      references: <BlockReference>[summaryReference],
    ),
    block(id: 'summary', sealed: true),
  ]);

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
    prepared: settled,
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

  // The table is declared from ordinary values and the same typed actions.
  final table = DeclarativeInput<FilteredListTableInputs, FilteredListAction>(
    contributionId: 'vendor.example.filtered-list',
    primitive: DeclarativePrimitive.table,
    resource: resource,
    inputs: FilteredListTableInputs(
      columns: const <String>['Name'],
      rows: <List<String>>[
        for (final item in inputs.items) <String>[item.title],
      ],
    ),
    actions: callback,
    position: position,
  );

  return ListExampleResult(
    inputs: inputs,
    actions: actions,
    table: table,
    unresolvedPrefixLength: pending.immutablePrefix.length,
    resolvedPrefixLength: settled.immutablePrefix.length,
    queryIsDeclaredInput: settled.referencedInputs.single.matches(queryFields),
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
  if (result.unresolvedPrefixLength != 0 || result.resolvedPrefixLength != 2) {
    throw StateError('cross-block reference did not gate the frozen prefix');
  }
  if (!result.queryIsDeclaredInput) {
    throw StateError('prepared value lost its declared plain input');
  }
  final table = result.table.unavailableGiven(<DeclarativePrimitive>[
    DeclarativePrimitive.form,
    DeclarativePrimitive.text,
  ]);
  if (table == null) {
    throw StateError('table contribution ignored the shell primitive set');
  }
  final error = result.inputs.error;
  if (error == null ||
      error.attribution.scope != result.inputs.scope ||
      error.attribution.resource == null) {
    throw StateError('list error lost its scope or resource attribution');
  }

  print('list query: ${result.inputs.query}');
  print('visible rows: ${result.inputs.items.length}');
  print('prepared blocks: ${result.inputs.prepared.blockIds.length}');
  print('table local state: ${table.contributionId}');
  print('error operation: ${error.attribution.operation}');
}
