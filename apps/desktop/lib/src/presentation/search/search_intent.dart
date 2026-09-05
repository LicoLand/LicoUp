import 'package:presentation_contract/presentation_contract.dart';

sealed class SearchIntent {
  const SearchIntent({this.trace});

  final TraceContext? trace;
}

final class OpenSearch extends SearchIntent {
  const OpenSearch({required this.localeCode, super.trace});

  final String localeCode;
}

final class UpdateSearchQuery extends SearchIntent {
  const UpdateSearchQuery(this.query, {super.trace});

  final String query;
}

final class SelectSearchResult extends SearchIntent {
  const SelectSearchResult(this.resultId, {super.trace});

  final String resultId;
}

final class DismissSearch extends SearchIntent {
  const DismissSearch({super.trace});
}
