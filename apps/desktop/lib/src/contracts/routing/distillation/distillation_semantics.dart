Set<String> distillationSemanticSections(String source) {
  final text = source.toLowerCase();
  final result = <String>{};
  bool hasAny(List<String> cues) => cues.any(text.contains);
  if (hasAny(const [
    'goal',
    'objective',
    'need to',
    'aim to',
    'deliver',
    'ship',
    '目标',
    '目的',
    '需要',
    '要做',
    '交付',
    '实现',
  ])) {
    result.add('objective');
  }
  if (hasAny(const [
    'current state',
    'status',
    'progress',
    'in progress',
    'landed',
    'completed',
    '当前',
    '现状',
    '状态',
    '进度',
    '已经',
    '已完成',
    '正在',
  ])) {
    result.add('currentState');
  }
  if (hasAny(const [
    'decision',
    'decided',
    'we chose',
    'we will use',
    'adopt',
    '决定',
    '选择',
    '采用',
    '确定',
    '选用',
  ])) {
    result.add('decisions');
  }
  if (hasAny(const [
    'constraint',
    'must not',
    'must ',
    'only ',
    'cannot',
    'never ',
    'forbid',
    '约束',
    '必须',
    '禁止',
    '不得',
    '不能',
    '仅能',
    '严禁',
  ])) {
    result.add('constraints');
  }
  if (hasAny(const [
    'open item',
    'open:',
    'todo',
    'remaining',
    'next step',
    'not yet',
    '待办',
    '剩余',
    '下一步',
    '未完成',
    '尚未',
    '仍需',
  ])) {
    result.add('openItems');
  }
  return result;
}

Set<String> distillationSemanticAnchors(String source) {
  final lower = source.toLowerCase();
  final anchors = <String>{};
  final ignored = <String>{
    'goal',
    'goals',
    'objective',
    'current',
    'state',
    'status',
    'progress',
    'decision',
    'decided',
    'constraint',
    'open',
    'item',
    'items',
    'todo',
    'must',
    'should',
    'with',
    'that',
    'this',
    'from',
    'into',
    'only',
    '目标',
    '目的',
    '当前',
    '状态',
    '进度',
    '决定',
    '选择',
    '约束',
    '必须',
    '禁止',
    '不得',
    '不能',
    '待办',
    '剩余',
    '下一步',
    '未完成',
  };
  for (final match in RegExp(
    r'[a-z0-9][a-z0-9_-]{2,}',
    unicode: true,
  ).allMatches(lower)) {
    final token = match.group(0)!;
    if (!ignored.contains(token)) {
      anchors.add(token);
    }
  }
  for (final match in RegExp(
    r'[\u3400-\u9fff]{2,}',
    unicode: true,
  ).allMatches(lower)) {
    final runes = match.group(0)!.runes.toList();
    for (var index = 0; index + 1 < runes.length; index++) {
      final token = String.fromCharCodes(runes.sublist(index, index + 2));
      if (!ignored.contains(token)) {
        anchors.add(token);
      }
    }
  }
  return anchors;
}
