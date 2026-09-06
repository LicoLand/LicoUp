import 'package:presentation_contract/presentation_contract.dart';

sealed class SearchEffect {
  const SearchEffect({this.trace});

  final TraceContext? trace;
}

final class SearchSelectionRejected extends SearchEffect {
  const SearchSelectionRejected(this.resultId, this.reasonCode, {super.trace});

  final String resultId;
  final String reasonCode;
}
