import 'package:licoup/src/contracts/project_plan_document.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';

/// The incomplete-import statement the project surface renders.
///
/// The project command family takes a canonical plan document on
/// `--stdin-json`; it never opens, scans or parses a source, and no model call
/// runs anywhere on that path. A caller reads an authorized source under its
/// own authorization and converts it deliberately. Until such a caller is
/// reachable from this client, the surface states the rule instead of inventing
/// a conversion: it submits nothing, imports nothing and reports no progress.
abstract final class ProjectImportDisclosure {
  static const String conversionKey = 'projects.import.conversion';
  static const String conversionText =
      'A plan arrives only as a caller-converted canonical document '
      '(licoup.project-plan/v1).';
  static const String conversionTextZh =
      '计划只以调用方转换后的规范文档（licoup.project-plan/v1）形式到达。';

  static const String noSourceReadingKey = 'projects.import.no-source-read';
  static const String noSourceReadingText =
      'This client never scans a source directory and never asks a model to '
      'convert one.';
  static const String noSourceReadingTextZh = '本客户端不扫描来源目录，也不调用模型进行转换。';

  static const String noProgressKey = 'projects.import.no-progress';
  static const String noProgressText =
      'No run, completion or acceptance fact is imported: the project command '
      'family publishes none, and a receipt is not evidence that work ran.';
  static const String noProgressTextZh =
      '不会导入任何运行、完成或验收事实：项目命令族不发布这些事实，导入回执也不证明工作已执行。';

  static const String noImporterKey = 'projects.import.no-importer';
  static const String noImporterText =
      'No converted document is reachable from this surface yet, so insert and '
      'preview stay unavailable and nothing is submitted on your behalf.';
  static const String noImporterTextZh =
      '当前界面还无法获得已转换的文档，因此插入与预览不可用，也不会代你提交任何内容。';

  /// The three statements every project surface renders, in order.
  static List<String> lines(LicoStrings strings) => <String>[
    strings.localized(
      conversionKey,
      strings.isChinese ? conversionTextZh : conversionText,
    ),
    strings.localized(
      noSourceReadingKey,
      strings.isChinese ? noSourceReadingTextZh : noSourceReadingText,
    ),
    strings.localized(
      noProgressKey,
      strings.isChinese ? noProgressTextZh : noProgressText,
    ),
  ];
}

/// The canonical plan document a caller converted for this surface, or none.
///
/// The interface is deliberately read-only and holds no conversion: a surface
/// can ask whether a document exists and submit it through the project intent
/// channel, and it has no way to read a source or to build a document from one.
/// A composition that has no importer supplies [UnconvertedProjectPlan], and
/// the surface then renders [ProjectImportDisclosure.noImporterText].
abstract interface class ProjectPlanSubmission {
  /// The caller-converted document this surface may preview and insert, or
  /// null when no caller converted one.
  ProjectPlanDocument? get convertedDocument;
}

/// The submission of a client that holds no converted document.
final class UnconvertedProjectPlan implements ProjectPlanSubmission {
  const UnconvertedProjectPlan();

  @override
  ProjectPlanDocument? get convertedDocument => null;
}
