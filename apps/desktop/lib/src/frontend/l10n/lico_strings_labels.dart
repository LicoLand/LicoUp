import 'package:flutter_client/src/contracts/presentation/layout_selection.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings_base.dart';

extension LicoStringsLabels on LicoStrings {
  // Shared interface actions and labels.
  String get clearSearch => isChinese ? '清除搜索' : 'Clear search';
  String get details => isChinese ? '详情' : 'Details';
  String get nativeDefault => isChinese ? '原生默认值' : 'Native default';
  String defaultValueDisplay(String value) =>
      isChinese ? '$value（默认）' : '$value (default)';
  String get reasoningSetting => isChinese ? '思考' : 'Reasoning';
  String get appearance => isChinese ? '外观' : 'Appearance';
  String get network => isChinese ? '网络' : 'Network';
  String get storageAndData => isChinese ? '存储与数据' : 'Storage & Data';
  String get diagnostics => isChinese ? '诊断' : 'Diagnostics';
  String get systemConfiguration => isChinese ? '系统配置' : 'System';
  String get clientUpdate => isChinese ? '客户端更新' : 'Client Update';
  String get clientUpdateHint => isChinese
      ? '发现、下载并校验已签名的公开更新清单。不需要商店账号。'
      : 'Discover, download, and verify signed public update manifests. No store account required.';
  String get checkUpdate => isChinese ? '检查更新' : 'Check Update';
  String get downloadUpdate => isChinese ? '下载更新' : 'Download Update';
  String get verifyUpdate => isChinese ? '校验更新' : 'Verify Update';
  String get planUpdateInstall => isChinese ? '生成安装计划' : 'Plan Install';
  String get channel => isChinese ? '通道' : 'Channel';
  String get availableVersion => isChinese ? '可用版本' : 'Available Version';
  String get digest => isChinese ? '摘要' : 'Digest';
  String get productionReady => isChinese ? '生产就绪' : 'Production Ready';
  String get yes => isChinese ? '是' : 'Yes';
  String get no => isChinese ? '否' : 'No';
  String get clientUpdatePhaseIdle => isChinese ? '空闲' : 'Idle';
  String get clientUpdatePhaseChecking => isChinese ? '检查中' : 'Checking';
  String get clientUpdatePhaseUpToDate => isChinese ? '已是最新' : 'Up to date';
  String get clientUpdatePhaseUpdateAvailable =>
      isChinese ? '有可用更新' : 'Update available';
  String get clientUpdatePhaseDownloading => isChinese ? '下载中' : 'Downloading';
  String get clientUpdatePhaseDownloaded => isChinese ? '已下载' : 'Downloaded';
  String get clientUpdatePhaseVerifying => isChinese ? '校验中' : 'Verifying';
  String get clientUpdatePhaseVerified => isChinese ? '已校验' : 'Verified';
  String get clientUpdatePhaseApplyPlanned =>
      isChinese ? '已规划安装' : 'Install planned';
  String get clientUpdatePhaseFailed => isChinese ? '失败' : 'Failed';
  String get done => isChinese ? '完成' : 'Done';
  String get customize => isChinese ? '自定义' : 'Customize';

  // Usage report chrome. Product and model names remain untranslated.
  String get noAgentUsageInLatestReport =>
      isChinese ? '最新报表中没有智能体用量' : 'No agent usage in the latest report';
  String get noModelUsageInLatestReport =>
      isChinese ? '最新报表中没有模型用量' : 'No model usage in the latest report';
  String get dailyUsageBreakdownUnavailable =>
      isChinese ? '暂无每日用量明细' : 'Daily usage breakdown unavailable';
  String get noModelUsageInLatestDailyBreakdown => isChinese
      ? '最新每日明细中没有模型用量'
      : 'No model usage in the latest daily breakdown';
  String get noAgentUsageInLatestDailyBreakdown => isChinese
      ? '最新每日明细中没有智能体用量'
      : 'No agent usage in the latest daily breakdown';
  String get usageOverTime => isChinese ? '用量趋势' : 'Usage Over Time';
  String get tokenUsageWindow =>
      isChinese ? 'Token 用量时间窗口' : 'Token usage window';
  String lastDays(int days) => isChinese ? '最近 $days 天' : 'Last $days days';
  String daysShort(int days) => isChinese ? '$days 天' : '${days}d';
  String get customDaysHint => isChinese ? '自定义天数' : 'Custom days';
  String get byAgent => isChinese ? '智能体' : 'By Agent';
  String get byModel => isChinese ? '模型' : 'By Model';
  String dailyTokenUsage(String date) =>
      isChinese ? '$date 每日 Token 用量' : 'Daily Token Usage · $date';
  String get unknown => isChinese ? '未知' : 'Unknown';
  String targetKindLabel(String value) {
    final normalized = value.trim().toLowerCase();
    return switch (normalized) {
      'cli' => 'CLI',
      'ide' => 'IDE',
      'plugin' => isChinese ? '插件' : 'Plugin',
      'editor' => isChinese ? '编辑器' : 'Editor',
      'desktop' => isChinese ? '桌面端' : 'Desktop',
      'desktop-agent' => isChinese ? '桌面智能体' : 'Desktop Agent',
      'native-history' => isChinese ? '原生历史' : 'Native History',
      _ => value,
    };
  }

  // Agent conversation support chrome.
  String get noSupportedTargetsDetected =>
      isChinese ? '未检测到支持的目标。' : 'No supported targets detected.';
  String get scrollToLoadMoreHistories =>
      isChinese ? '滚动继续加载历史' : 'Scroll to load more histories';
  String get loadingMoreHistories =>
      isChinese ? '正在加载更多历史...' : 'Loading more histories...';
  String get searchHistories => isChinese ? '搜索历史' : 'Search histories';
  String get searchConversations => isChinese ? '搜索对话' : 'Search conversations';
  String get searchConversationsHint => isChinese
      ? '搜索功能和所有对话的标题、内容'
      : 'Search features, conversation titles, and content';
  String get searchFeaturesGroup => isChinese ? '功能' : 'Features';
  String get noConversationSearchResults =>
      isChinese ? '没有匹配的对话' : 'No matching conversations';
  String get collapseHistory => isChinese ? '收起历史' : 'Collapse history';
  String get expandHistory => isChinese ? '展开历史' : 'Expand history';
  // File chooser labels. File formats are intentionally not translated.
  String get plainTextFile => isChinese ? '文本' : 'Text';
  String get directory => isChinese ? '目录' : 'Directory';

  String statusCaptionLabel(String value) {
    if (!isChinese) {
      return value;
    }
    return switch (value.trim()) {
      'Agent archive' => '智能体归档',
      'Agent chat' => '智能体对话',
      'Agent orchestration' => '智能体编排',
      'Agent tabs' => '智能体标签页',
      'Agent usage' => '智能体用量',
      'Appearance' => '外观',
      'Client logs' => '客户端日志',
      'Conversation archive' => '对话归档',
      'Error' => '错误',
      'LicoArc client' => '客户端',
      'Mobile agents' => '移动端智能体',
      'Mobile relay' => '移动中转',
      'Project archive' => '项目归档',
      'Ready' => '就绪',
      'Secure Mesh' => '安全网格',
      'Settings' => '设置',
      'Skill Hub' => '技能中心',
      'Snapshots' => '快照',
      'Target inspect' => '目标检查',
      'Targets' => '目标',
      _ => value,
    };
  }

  // Skill Hub interface chrome. Skill names and skill-authored descriptions
  // are source content and intentionally remain unchanged.
  String get skillHubSubtitle => isChinese
      ? '查看、配对并安装本机智能体可加载的技能。'
      : 'Browse, pair, and install skills loadable by local agents.';
  String get refreshSkills => isChinese ? '刷新技能' : 'Refresh Skills';
  String get showSkillHubSettings =>
      isChinese ? '显示技能设置' : 'Show Skill Settings';
  String get hideSkillHubSettings =>
      isChinese ? '隐藏技能设置' : 'Hide Skill Settings';
  String get allSkills => isChinese ? '全部技能' : 'All Skills';
  String get publicSkills => isChinese ? '公共技能' : 'Public Skills';
  String get privateSkills => isChinese ? '私有技能' : 'Private Skills';
  String get publicLabel => isChinese ? '公共' : 'Public';
  String get privateLabel => isChinese ? '私有' : 'Private';
  String get noSkillsFound => isChinese ? '未发现技能' : 'No Skills Found';
  String get refreshSkillsHint => isChinese
      ? '刷新后会重新扫描本机技能目录。'
      : 'Refresh to scan local skill directories again.';
  String get noDescription => isChinese ? '暂无描述' : 'No description';
  String get skillId => isChinese ? '技能 ID' : 'Skill ID';
  String get author => isChinese ? '作者' : 'Author';
  String get customizeSkillIcon =>
      isChinese ? '自定义技能图标' : 'Customize Skill Icon';
  String get skillIconColor => isChinese ? '图标颜色' : 'Icon Color';
  String get skillIconGlyph => isChinese ? '图标样式' : 'Icon Glyph';
  String get version => isChinese ? '版本' : 'Version';
  String get path => isChinese ? '路径' : 'Path';
  String get type => isChinese ? '类型' : 'Type';
  String get description => isChinese ? '描述' : 'Description';
  String get request => isChinese ? '请求' : 'Request';
  String get approve => isChinese ? '批准' : 'Approve';
  String get revoke => isChinese ? '撤销' : 'Revoke';
  String get installFromGitHub =>
      isChinese ? '从 GitHub 安装' : 'Install from GitHub';
  String get installRoot => isChinese ? '安装目录' : 'Install Root';
  String get overwrite => isChinese ? '覆盖' : 'Overwrite';
  String get pin => isChinese ? '固定' : 'Pin';
  String get preview => isChinese ? '预览' : 'Preview';
  String get install => isChinese ? '安装' : 'Install';
  String get installPlan => isChinese ? '安装计划' : 'Install Plan';
  String get installResult => isChinese ? '安装结果' : 'Install Result';
  String get rollbackSnapshot => isChinese ? '回滚快照' : 'Rollback Snapshot';
  String get rollback => isChinese ? '回滚' : 'Rollback';

  String get refreshAgents => isChinese ? '刷新智能体' : 'Refresh Agents';
  String get scanQrCode => isChinese ? '扫描二维码' : 'Scan QR Code';
  String get addDevice => isChinese ? '添加设备' : 'Add Device';
  String get pairDevice => isChinese ? '配对设备' : 'Pair Device';
  String get pinToTop => isChinese ? '置顶' : 'Pin To Top';
  String get unpinFromTop => isChinese ? '取消置顶' : 'Unpin From Top';
  String get pinned => isChinese ? '已置顶' : 'Pinned';
  String get pairingInviteToken => isChinese ? '邀请令牌' : 'Invite Token';
  String get pairingQrDetected =>
      isChinese ? '已识别二维码，正在配对...' : 'QR detected, pairing...';
  String get pairingScanSuccess =>
      isChinese ? '扫描成功，设备已配对。' : 'Scan successful. Device paired.';
  String get pairingScanFailed => isChinese
      ? '配对失败，请重新扫描或粘贴邀请。'
      : 'Pairing failed. Scan again or paste the invite.';
  String get unpairedDevice => isChinese ? '未配对设备' : 'Unpaired Device';
  String get mac => 'Mac';

  String get addTarget => isChinese ? '添加目标' : 'Add target';
  String get adding => isChinese ? '添加中...' : 'Adding...';
  String get rescan => isChinese ? '重新扫描' : 'Rescan';
  String get scanning => isChinese ? '扫描中...' : 'Scanning...';
  String get scanningLocalAgents =>
      isChinese ? '正在扫描可用智能体...' : 'Scanning available agents...';
  String get noLocalAgentsFound =>
      isChinese ? '未发现可用智能体' : 'No available agents found';
  String get agentTabNeedsApproval => isChinese ? '等待批准' : 'Needs approval';
  String get agentTabWorkFinished => isChinese ? '工作已完成' : 'Work finished';
  String get selectAgentToView => isChinese
      ? '选择一个智能体查看历史并对话'
      : 'Select an agent to view histories and chat';

  String get target => isChinese ? '目标' : 'Target';
  String get configPath => isChinese ? '配置路径' : 'Config path';
  String get binaryPath => isChinese ? '程序路径' : 'Binary path';
  String get historyRoot => isChinese ? '历史目录' : 'History root';
  String get cancel => isChinese ? '取消' : 'Cancel';
  String get apply => isChinese ? '应用' : 'Apply';
  String get inspect => isChinese ? '查看' : 'Inspect';
  String get plan => isChinese ? '计划' : 'Plan';

  String get configured => isChinese ? '已配置' : 'Configured';
  String get detected => isChinese ? '已检测到' : 'Detected';
  String get manual => isChinese ? '手动添加' : 'Manual';
  String get unavailable => isChinese ? '不可用' : 'Unavailable';
  String get notConfigured => isChinese ? '未配置' : 'Not configured';

  String get historyConversations =>
      isChinese ? '历史对话' : 'Conversation history';
  String get agentsSidebarConversations => isChinese ? '对话' : 'CONVERSATIONS';
  String get ungroupedConversationProject => isChinese ? '未关联项目' : 'No project';
  String get historyConversationSearchHint =>
      isChinese ? '搜索历史对话' : 'Search conversations';
  String get noMatchingNativeHistories =>
      isChinese ? '没有匹配的历史对话' : 'No matching histories';
  String conversationCount(int count) =>
      isChinese ? '$count 条对话' : '$count conversations';
  String get conversations => isChinese ? '对话' : 'Conversations';
  String get newConversation => isChinese ? '新对话' : 'New Conversation';
  String get recycleBin => isChinese ? '回收站' : 'Recycle Bin';
  String get archivedConversations => isChinese ? '已归档' : 'Archived';
  String get recentConversations => isChinese ? '最近对话' : 'Recent conversations';
  String get noConversationsYet => isChinese ? '还没有对话' : 'No conversations yet';
  String get noTrashedConversations =>
      isChinese ? '回收站为空' : 'Recycle bin is empty';
  String get delete => isChinese ? '删除' : 'Delete';
  String get restore => isChinese ? '恢复' : 'Restore';
  String get confirmDeleteConversationTitle =>
      isChinese ? '删除这段对话？' : 'Delete this conversation?';
  String confirmDeleteConversationMessage(String title) => isChinese
      ? '“$title” 会移入本机回收站，并在 30 天后清理。'
      : '"$title" will move to the local recycle bin and be cleared after 30 days.';
  String get deletedConversationsExpire => isChinese
      ? '删除的对话会在本机回收站保留 30 天。'
      : 'Deleted conversations stay in the local recycle bin for 30 days.';
  String get loading => isChinese ? '加载中...' : 'Loading...';
  String get loadingNativeHistories =>
      isChinese ? '正在加载原生智能体历史...' : 'Loading native agent histories...';
  String get noNativeHistories =>
      isChinese ? '暂无原生智能体历史' : 'No native agent histories yet';
  String get deleteNativeHistory =>
      isChinese ? '删除原生智能体历史' : 'Delete native agent history';
  String get archiveAgentConversations =>
      isChinese ? '归档当前智能体对话' : 'Archive agent conversations';
  String get collapseHistoryConversations =>
      isChinese ? '收起历史对话' : 'Collapse conversation history';
  String get expandHistoryConversations =>
      isChinese ? '展开历史对话' : 'Expand conversation history';
  String get collapseAgentsSidebar => isChinese ? '收起侧边栏' : 'Collapse sidebar';
  String get expandAgentsSidebar => isChinese ? '展开侧边栏' : 'Expand sidebar';
  String messagesCount(int count) =>
      isChinese ? '$count 条消息' : '$count messages';
  String get noMessagesInHistory => isChinese ? '还没有消息' : 'No messages yet';

  String get keywords => isChinese ? '关键词' : 'Keywords';
  String get archiveDirectory => isChinese ? '归档目录' : 'Archive directory';
  String get archive => isChinese ? '归档' : 'Archive';
  String get backupConversations =>
      isChinese ? '备份对话' : 'Back up conversations';
  String get allConversations => isChinese ? '全部对话' : 'All conversations';
  String get exactKeyword => isChinese ? '精确关键词' : 'Exact keyword';
  String get archiveDestinationRequired => isChinese
      ? '请先在设置中选择本机归档目录。'
      : 'Choose a local archive directory in Settings first.';
  String archiveDestination(String path) =>
      isChinese ? '本机归档目录：$path' : 'Local archive directory: $path';
  String get previewAndBackup => isChinese ? '预览并备份' : 'Preview & Back Up';
  String get openDirectory => isChinese ? '跳转' : 'Open';
  String recordsCount(String count) =>
      isChinese ? '$count 条记录' : '$count records';

  String get you => isChinese ? '你' : 'You';
  String get agent => isChinese ? '智能体' : 'Agent';
  String get subagentTask => isChinese ? '子智能体任务' : 'Subagent task';
  String get agentProcess => isChinese ? '智能体过程' : 'Agent process';
  String get workedBriefly => isChinese ? '短暂处理' : 'Worked briefly';
  String workedForSeconds(int seconds) =>
      isChinese ? '处理了 $seconds秒' : 'Worked for ${seconds}s';
  String workedForMinutes(int minutes, int seconds) {
    if (isChinese) {
      return seconds == 0 ? '处理了 $minutes分钟' : '处理了 $minutes分钟 $seconds秒';
    }
    return seconds == 0
        ? 'Worked for ${minutes}m'
        : 'Worked for ${minutes}m ${seconds}s';
  }

  String processSteps(int count, {required bool truncated}) {
    final value = '$count${truncated ? '+' : ''}';
    return isChinese
        ? '$value 个步骤'
        : '$value ${count == 1 && !truncated ? 'step' : 'steps'}';
  }

  String processIssues(int count) =>
      isChinese ? '$count 个问题' : '$count ${count == 1 ? 'issue' : 'issues'}';
  String get expandProcessDetails =>
      isChinese ? '展开过程详情' : 'Expand process details';
  String get collapseProcessDetails =>
      isChinese ? '收起过程详情' : 'Collapse process details';
  String get reasoningSummary => isChinese ? '思考摘要' : 'Reasoning summary';
  String get providerSummary => isChinese ? '提供方摘要' : 'Provider summary';
  String get toolCall => isChinese ? '工具调用' : 'Tool call';
  String get nativeAgentActivity =>
      isChinese ? '原生智能体活动' : 'Native agent activity';
  String get toolResult => isChinese ? '工具结果' : 'Tool result';
  String get nativeAgentResult => isChinese ? '原生智能体结果' : 'Native agent result';
  String get reasoning => isChinese ? '思考' : 'Reasoning';
  String get sensitiveDetailsHidden =>
      isChinese ? '敏感详情已隐藏' : 'Sensitive details hidden';
  String get metadata => isChinese ? '元数据' : 'Metadata';
  String get processError => isChinese ? '错误' : 'Error';
  String get nativeAgentError => isChinese ? '原生智能体错误' : 'Native agent error';
  String get nativeEvent => isChinese ? '原生事件' : 'Native event';
  String get nativeAgentEvent => isChinese ? '原生智能体事件' : 'Native agent event';
  String get additionalOperationsHidden => isChinese
      ? '为保持对话流畅，其余操作已隐藏。'
      : 'Additional operations are hidden to keep this conversation responsive.';
  String get conversationHistoryTruncated => isChinese
      ? '较早的历史消息未载入；当前显示最近的对话。'
      : 'Earlier history was not loaded; the most recent conversation is shown.';
  String get conversationDetailsTruncated => isChinese
      ? '部分嵌套过程详情未载入；最终对话消息仍保留。'
      : 'Some nested process details were not loaded; final conversation messages remain available.';
  String get conversationHistoryAndDetailsTruncated => isChinese
      ? '较早消息和部分嵌套过程详情未载入；当前显示最近的完整对话骨架。'
      : 'Earlier messages and some nested process details were not loaded; the recent conversation outline remains available.';
  String get invocationDetailsHidden =>
      isChinese ? '调用详情已隐藏。' : 'Invocation details are hidden.';
  String get toolResultRecorded =>
      isChinese ? '已记录原生工具结果。' : 'The native tool result was recorded.';
  String get reasoningDetailsRedacted =>
      isChinese ? '思考详情已脱敏。' : 'Reasoning details are redacted.';
  String get nativeMetadataHidden =>
      isChinese ? '原生敏感元数据已隐藏。' : 'Sensitive native metadata is hidden.';
  String get nativeAgentErrorReported =>
      isChinese ? '原生智能体报告了错误。' : 'The native agent reported an error.';
  String get nativeEventDetailsHidden =>
      isChinese ? '原生事件详情已隐藏。' : 'Native event details are hidden.';
  String get orchestrationFallback => orchestrationSequentialFallback;
  String get orchestrationWorkType => orchestrationDynamicAllocation;
  String get orchestrationSequentialFallback =>
      isChinese ? '顺序降级' : 'Sequential Fallback';
  String get orchestrationDynamicAllocation =>
      isChinese ? '动态分配' : 'Dynamic Routing';
  String get automatic => isChinese ? '自动' : 'Auto';
  String get codeWork => isChinese ? '写代码' : 'Code';
  String get documentationWork => isChinese ? '写文档' : 'Docs';
  String get primaryAgent => isChinese ? '主智能体' : 'Primary Agent';
  String get primaryAgentShort => isChinese ? '主' : 'P';
  String get resetCircuitBreaker => isChinese ? '重置熔断' : 'Reset Circuit';
  String get circuitBroken => isChinese ? '已熔断' : 'Circuit Open';
  String get commander => isChinese ? '指挥官' : 'Commander';
  String get agentClient => isChinese ? '智能体客户端' : 'Agent Client';
  String get noModelsFound => isChinese ? '未发现模型' : 'No Models Found';
  String get noReasoningEffortsFound =>
      isChinese ? '未发现思考强度' : 'No Reasoning Efforts Found';
  String get noModelLibraryEntries =>
      isChinese ? '尚未添加模型组合' : 'No Model Combinations Added';
  String get defaultPolicy => isChinese ? '默认策略' : 'Default Policy';
  String get editPolicy => isChinese ? '编辑策略' : 'Edit Policy';
  String get renamePolicy => isChinese ? '重命名策略' : 'Rename Policy';
  String get policyName => isChinese ? '策略名称' : 'Policy Name';
  String get addRule => isChinese ? '新增规则' : 'Add Rule';
  String ruleLabel(int index) => isChinese ? '规则 $index' : 'Rule $index';
  String get configurePolicyBeforeSend =>
      isChinese ? '先配置策略' : 'Configure a policy first';
  String get conversationParitySendDisabled =>
      isChinese ? '发送已关闭' : 'Sending disabled';
  String get conversationParityCapabilities =>
      isChinese ? '能力矩阵' : 'Capability matrix';
  String get conversationParityCapabilitiesUnavailable =>
      isChinese ? '暂无能力矩阵' : 'Capability matrix unavailable';
  String get conversationParityEvidenceAge =>
      isChinese ? '证据状态' : 'Evidence age';
  String get conversationParityEvidenceNote =>
      isChinese ? '验收记录' : 'Acceptance note';
  String conversationParityEvidenceAgeValue(String ageClass) {
    return switch (ageClass) {
      'current' => isChinese ? '当前' : 'Current',
      'stale' => isChinese ? '已过期' : 'Stale',
      'missing' => isChinese ? '缺失' : 'Missing',
      _ => isChinese ? '无' : 'Absent',
    };
  }

  String conversationParityReason(String code) {
    return switch (code) {
      'evidence_missing' =>
        isChinese
            ? '当前版本尚未生成对等验收证据。'
            : 'Parity evidence has not been generated for this version.',
      'evidence_incomplete' =>
        isChinese
            ? '当前版本的对等验收证据不完整。'
            : 'Parity evidence is incomplete for this version.',
      'evidence_stale_or_incomplete' =>
        isChinese
            ? '对等验收证据已过期或不完整。'
            : 'Parity evidence is stale or incomplete.',
      'runtime_evidence_binding_mismatch' =>
        isChinese
            ? '运行时证据绑定不匹配，请重新扫描智能体。'
            : 'Runtime evidence binding mismatch; rescan agents.',
      'official_native_lane_missing' =>
        isChinese
            ? '缺少可公开使用的官方会话通道。'
            : 'No official public conversation lane is available.',
      'exact_session_resume_unavailable' =>
        isChinese
            ? '无法在官方通道上精确恢复原生会话。'
            : 'Exact native session resume is unavailable on the official lane.',
      'antigravity_cli_structured_transport_unavailable' =>
        isChinese
            ? 'Antigravity CLI 没有保持消息与会话 ID 离开进程参数的结构化传输。'
            : 'Antigravity CLI has no structured transport that keeps messages and conversation IDs out of process arguments.',
      'native_agent_executable_not_detected' =>
        isChinese
            ? '未检测到对应的本地 CLI 可执行程序。'
            : 'The local CLI executable was not detected.',
      'native_agent_runtime_profile_unavailable' =>
        isChinese
            ? '没有找到对应的本地会话驱动。'
            : 'No local conversation driver is available for this agent.',
      'runtime_message_send_unavailable' =>
        isChinese
            ? '当前扫描结果没有可执行的消息发送路径。'
            : 'The current scan has no executable message-send path.',
      'orchestration_policy_required' => configurePolicyBeforeSend,
      'orchestration_targets_unavailable' =>
        isChinese
            ? '当前策略没有可用的发送目标。'
            : 'The current policy has no available send targets.',
      _ => isChinese ? '操作不可用：$code' : 'Operation unavailable: $code',
    };
  }

  String messageTarget(String targetLabel) =>
      isChinese ? '发送给 $targetLabel' : 'Message $targetLabel';
  String get send => isChinese ? '发送' : 'Send';
  String conversationSendFailed(String reason) =>
      isChinese ? '发送失败：$reason' : 'Send failed: $reason';

  String get appearancePreset => isChinese ? '外观方案' : 'Appearance Preset';
  String get layoutProfile => isChinese ? '界面布局' : 'Interface Layout';
  String get layoutProfileDescription => isChinese
      ? '预览并选择整套组件风格、页面排布与交互外观。'
      : 'Preview and choose a complete component, arrangement, and interaction system.';
  String get previewLayout => isChinese ? '预览布局' : 'Preview layout';
  String get confirmLayout => isChinese ? '使用此布局' : 'Use this layout';
  String get cancelLayoutPreview => isChinese ? '取消预览' : 'Cancel preview';
  String get resetLayout =>
      isChinese ? '恢复系统默认布局' : 'Restore system default layout';
  String get layoutLoading => isChinese ? '正在加载布局…' : 'Loading layouts…';
  String get layoutPreviewing => isChinese ? '正在预览布局' : 'Previewing layout';
  String get layoutCommitting => isChinese ? '正在保存布局…' : 'Saving layout…';
  String get currentLayout => isChinese ? '当前布局' : 'Current layout';
  String layoutSelectionError(LayoutSelectionErrorCode code) => switch (code) {
    LayoutSelectionErrorCode.invalidProfile =>
      isChinese
          ? '布局标识无效，已保留当前布局。'
          : 'The layout identifier is invalid. The current layout was kept.',
    LayoutSelectionErrorCode.unavailableProfile =>
      isChinese
          ? '此布局当前不可用，已保留当前布局。'
          : 'That layout is unavailable. The current layout was kept.',
    LayoutSelectionErrorCode.invalidStoredPreference =>
      isChinese
          ? '已忽略无效的布局偏好并恢复默认布局。'
          : 'An invalid layout preference was ignored and the default was restored.',
    LayoutSelectionErrorCode.persistenceFailed =>
      isChinese ? '无法保存布局，请稍后重试。' : 'The layout could not be saved. Try again.',
    LayoutSelectionErrorCode.previewExpired =>
      isChinese
          ? '布局预览已结束，已恢复原布局。'
          : 'The layout preview ended and the previous layout was restored.',
  };

  String get appearancePresetDirectory =>
      isChinese ? '外观方案目录' : 'Appearance Preset Directory';
  String get reloadPresets => isChinese ? '重新加载方案' : 'Reload Presets';
  String invalidPresetConfigs(int count) =>
      isChinese ? '$count 个外观方案配置无效' : '$count invalid preset configs';
  String get portableData => isChinese ? '便携数据' : 'Portable Data';
  String get clientLogs => isChinese ? '客户端日志' : 'Client Logs';
  String get exportLogs => isChinese ? '导出日志' : 'Export Logs';
  String get exportLogsDescription => '';
  String get exportingLogs => isChinese ? '正在导出日志...' : 'Exporting logs...';
  String get conversationArchiveRoot =>
      isChinese ? '对话归档目录' : 'Conversation Archive Directory';
  String get refreshArchiveRoot =>
      isChinese ? '刷新归档目录' : 'Refresh Archive Directory';
  String get snapshotRootPath => isChinese ? '快照根路径' : 'Snapshot Root Path';
  String get save => isChinese ? '保存' : 'Save';
  String get recommendedPlugins => isChinese ? '推荐插件' : 'Recommended Plugins';

  String get secureMesh => isChinese ? '安全网格' : 'Secure Mesh';
  String get refresh => isChinese ? '刷新' : 'Refresh';
  String get protocol => isChinese ? '协议' : 'Protocol';
  String get pairwise => isChinese ? '点对点' : 'Pairwise';
  String get file => isChinese ? '文件' : 'File';
  String get fileRoute => isChinese ? '文件路由' : 'File Route';
  String get fileSync => isChinese ? '文件同步' : 'File Sync';
  String get fileSyncHint => isChinese
      ? '选择文件与目标目录，评估路由后需本地确认才会写入。不会自动预览或入库。'
      : 'Pick a file and destination, evaluate the route, then confirm locally before write. No auto-preview or ingestion.';
  String get chooseFile => isChinese ? '选择文件' : 'Choose File';
  String get chooseDestination => isChinese ? '选择目标目录' : 'Choose Destination';
  String get prepareFileSync => isChinese ? '准备同步' : 'Prepare Sync';
  String get fileSyncSize => isChinese ? '大小' : 'Size';
  String get destination => isChinese ? '目标目录' : 'Destination';
  String get notSelected => isChinese ? '未选择' : 'Not selected';
  String get fileSyncConfirmationPrompt => isChinese
      ? '确认将文件写入所选目标目录？写入前不会自动打开或解析内容。'
      : 'Confirm writing this file into the selected destination? Content is not auto-opened or ingested before write.';
  String get confirmWrite => isChinese ? '确认写入' : 'Confirm Write';
  String get rejectWrite => isChinese ? '拒绝写入' : 'Reject Write';
  String get fileSyncQueue => isChinese ? '传输队列' : 'Transfer Queue';
  String get fileSyncStatusDrafting => isChinese ? '起草中' : 'Drafting';
  String get fileSyncStatusEvaluating => isChinese ? '评估中' : 'Evaluating';
  String get fileSyncStatusAwaitingConfirmation =>
      isChinese ? '等待确认' : 'Awaiting confirmation';
  String get fileSyncStatusConfirmed => isChinese ? '已确认' : 'Confirmed';
  String get fileSyncStatusRejected => isChinese ? '已拒绝' : 'Rejected';
  String get fileSyncStatusFailed => isChinese ? '失败' : 'Failed';
  String get remoteApproval => isChinese ? '远程审批' : 'Remote Approval';
  String get remoteApprovalHint => isChinese
      ? '来自可信客户端的加密审批请求会出现在此收件箱。详情保持密文，仅显示摘要。'
      : 'Encrypted approval requests from trusted clients appear here. Detail stays ciphertext; only the summary is shown.';
  String get remoteApprovalEmpty =>
      isChinese ? '当前没有待处理的审批。' : 'No pending approvals.';
  String get remoteApprovalHistory => isChinese ? '审批历史' : 'Approval History';
  String get remoteApprovalStatusPending => isChinese ? '待处理' : 'Pending';
  String get remoteApprovalStatusAllowed => isChinese ? '已批准' : 'Allowed';
  String get remoteApprovalStatusDenied => isChinese ? '已拒绝' : 'Denied';
  String get remoteApprovalStatusExpired => isChinese ? '已过期' : 'Expired';
  String get remoteApprovalStatusFailed => isChinese ? '失败' : 'Failed';
  String get risk => isChinese ? '风险' : 'Risk';
  String get summary => isChinese ? '摘要' : 'Summary';
  String get tools => isChinese ? '工具' : 'Tools';
  String get allow => isChinese ? '允许' : 'Allow';
  String get deny => isChinese ? '拒绝' : 'Deny';
  String get skillSync => isChinese ? '技能同步' : 'Skill Sync';
  String get skillSyncHint => isChinese
      ? '选择技能与目标智能体，确认后再安装。'
      : 'Choose a skill and target agent, then confirm before install.';
  String get skillSyncPrepare => isChinese ? '准备技能同步' : 'Prepare Skill Sync';
  String get skillSyncConfirmInstall => isChinese ? '确认安装' : 'Confirm Install';
  String get skillSyncRejectInstall => isChinese ? '拒绝安装' : 'Reject Install';
  String get skillSyncQueue => isChinese ? '技能同步队列' : 'Skill Sync Queue';
  String get skillSyncStatusDrafting => isChinese ? '起草中' : 'Drafting';
  String get skillSyncStatusTransferring => isChinese ? '传输中' : 'Transferring';
  String get skillSyncStatusAwaitingInstall =>
      isChinese ? '等待安装' : 'Awaiting install';
  String get skillSyncStatusInstalling => isChinese ? '安装中' : 'Installing';
  String get skillSyncStatusInstalled => isChinese ? '已安装' : 'Installed';
  String get skillSyncStatusFailed => isChinese ? '失败' : 'Failed';
  String get sourceAgent => isChinese ? '源智能体' : 'Source Agent';
  String get targetAgent => isChinese ? '目标智能体' : 'Target Agent';
  String get packageDigest => isChinese ? '包摘要' : 'Package Digest';
  String get fileReceiveDestination =>
      isChinese ? '文件接收位置' : 'File Receive Destination';
  String get evaluatingFileReceiveDestination => isChinese
      ? '正在评估安全网格文件接收位置。'
      : 'Evaluating Secure Mesh file receive destination.';
  String get fileReceiveDestinationEvaluated => isChinese
      ? '安全网格文件接收位置已评估。'
      : 'Secure Mesh file receive destination evaluated.';
  String get fileReceiveDestinationEvaluationFailed => isChinese
      ? '安全网格文件接收位置评估失败。'
      : 'Secure Mesh file receive destination evaluation failed.';
  String get command => isChinese ? '命令' : 'Command';
  String get deviceTrust => isChinese ? '设备信任' : 'Device Trust';
  String get trustPolicy => isChinese ? '信任策略' : 'Trust Policy';
  String get adapter => isChinese ? '适配器' : 'Adapter';
  String get readiness => isChinese ? '就绪状态' : 'Readiness';
  String get e2eeReadiness => isChinese ? '端到端加密就绪' : 'E2EE Readiness';
  String get secretStore => isChinese ? '密钥存储' : 'Secret Store';
  String get gateway => isChinese ? '网关' : 'Gateway';
  String get licoArcGateway => isChinese ? 'Lico Arc 网关' : 'Lico Arc Gateway';
  String get customGateway => isChinese ? '自定义网关' : 'Custom Gateway';
  String get privateGateway => isChinese ? '自定义网关' : 'Custom Gateway';
  String get gatewayLocked =>
      isChinese ? '默认 Lico Arc 网关不可编辑' : 'Default Lico Arc gateway is locked';
  String get saveGateway => isChinese ? '保存网关' : 'Save Gateway';
  String get defaultLabel => isChinese ? '默认' : 'Default';
  String get active => isChinese ? '当前' : 'Active';
  String get pairing => isChinese ? '配对' : 'Pairing';
  String get tapToGeneratePairingQr =>
      isChinese ? '点击生成配对码' : 'Tap to generate pairing code';
  String get pairingQrPlaceholder => isChinese ? '配对二维码' : 'Pairing QR code';
  String get deviceTrustVerification =>
      isChinese ? '设备信任验证' : 'Device Trust Verification';
  String get trustVerified =>
      isChinese ? '已验证，可发送加密内容' : 'Verified — protected send enabled';
  String get trustUnverified =>
      isChinese ? '尚未验证，已阻止发送' : 'Unverified — protected send blocked';
  String get trustKeyChanged =>
      isChinese ? '密钥已变化，必须重新验证' : 'Key changed — verification required';
  String get trustRevoked =>
      isChinese ? '信任已撤销，已阻止发送' : 'Trust revoked — protected send blocked';
  String get safetyNumber => isChinese ? '60 位安全码' : '60-Digit Safety Number';
  String get localFingerprint => isChinese ? '本机指纹' : 'Local Fingerprint';
  String get peerFingerprint => isChinese ? '对端指纹' : 'Peer Fingerprint';
  String get verificationMethod => isChinese ? '验证方式' : 'Verification Method';
  String get securityCapabilities =>
      isChinese ? '安全能力' : 'Security Capabilities';
  String get expandSecurityCapabilities =>
      isChinese ? '展开安全能力' : 'Expand security capabilities';
  String get collapseSecurityCapabilities =>
      isChinese ? '收起安全能力' : 'Collapse security capabilities';
  String get localEndpointCapabilities =>
      isChinese ? '本机能力集合' : 'Local Endpoint Capability Sets';
  String get peerEndpointCapabilities =>
      isChinese ? '对端能力集合' : 'Peer Endpoint Capability Sets';
  String get negotiatedProtocolCapabilities =>
      isChinese ? '已协商协议能力' : 'Negotiated Protocol Capabilities';
  String get enabledCapabilities => isChinese ? '已启用' : 'Enabled';
  String get availableCapabilities => isChinese ? '可用' : 'Available';
  String get unavailableCapabilities => isChinese ? '不可用' : 'Unavailable';
  String get unverifiedCapabilities => isChinese ? '未验证' : 'Unverified';
  String get missingMandatoryCapabilities =>
      isChinese ? '缺失的强制能力' : 'Missing Mandatory Capabilities';
  String get capabilityReasons => isChinese ? '原因' : 'Reasons';
  String get selectedCustody => isChinese ? '已选择的密钥托管' : 'Selected Custody';
  String get custodyRestartSemantics =>
      isChinese ? '重启后的安全语义' : 'Restart Security Semantics';
  String get enabledCustodyHardening =>
      isChinese ? '已启用的托管加固' : 'Enabled Custody Hardening';
  String get capabilityDependencies =>
      isChinese ? '能力依赖关系' : 'Capability Dependencies';
  String get noCapabilities => isChinese ? '无' : 'None';
  String get compareSafetyNumber => isChinese
      ? '请在两台设备上逐组核对安全码或扫描验证二维码。任何一组不同都不要继续发送。'
      : 'Compare every group on both devices or scan the verification QR code. Do not send if any group differs.';
  String get createCode => isChinese ? '创建配对码' : 'Create Code';
  String get copyPairingCode => isChinese ? '复制配对码' : 'Copy Pairing Code';
  String get pairingCodeCopied => isChinese ? '配对码已复制' : 'Pairing Code Copied';
  String get oneTimePairingCode =>
      isChinese ? '一次性配对码' : 'One-Time Pairing Code';
  String get oneTimePairingCodeNotice => isChinese
      ? '此配对码只会展示一次。重新生成会清除当前码并创建全新的配对码。'
      : 'This pairing code is shown once. Regenerating clears it and creates a new code.';
  String get scanPairingPrompt => isChinese
      ? '点击右上角扫描按钮，扫描 Mac 上的 Lico Arc 配对二维码。'
      : 'Tap the scan button in the top-right corner to scan the Lico Arc pairing QR code on your Mac.';
  String get close => isChinese ? '关闭' : 'Close';
  String get scanQrToPairPhone =>
      isChinese ? '扫描此二维码完成手机配对' : 'Scan This QR Code To Pair Your Phone';
  String get status => isChinese ? '状态' : 'Status';
  String get model => isChinese ? '模型' : 'Model';
  String get modelLibrary => isChinese ? '模型库' : 'Model Library';
  String get reasoningEffort => isChinese ? '思考强度' : 'Reasoning Effort';
  String reasoningEffortOptionLabel(String value, String fallback) {
    return switch (value.trim().toLowerCase()) {
      '' => isChinese ? '自动' : 'Auto',
      'low' => isChinese ? '低' : 'Low',
      'medium' => isChinese ? '中' : 'Medium',
      'high' => isChinese ? '高' : 'High',
      'enabled' => isChinese ? '启用' : 'Enabled',
      'disabled' => isChinese ? '关闭' : 'Disabled',
      _ => fallback,
    };
  }

  String get paired => isChinese ? '已配对' : 'Paired';
  String get waiting => isChinese ? '等待中' : 'Waiting';
  String get pairingId => isChinese ? '配对 ID' : 'Pairing ID';
  String get expires => isChinese ? '过期时间' : 'Expires';
  String get pairingCode => isChinese ? '配对码' : 'Pairing Code';
  String get relayStatus => isChinese ? '中转状态' : 'Relay Status';
  String get pairedComputer => isChinese ? '配对电脑' : 'Paired Computer';
  String get arcDesktop => isChinese ? 'Arc Desktop' : 'Arc Desktop';
  String get availableAgents => isChinese ? '可用智能体' : 'Available Agents';
  String get desktopAgents => isChinese ? '电脑智能体' : 'Desktop Agents';
  String get secureRelay =>
      isChinese ? '通过电脑安全中转' : 'Secure Relay Through Computer';
  String get noDesktopAgents =>
      isChinese ? '这台电脑暂未回显可用智能体。' : 'No desktop agents are available yet.';
  String displayStatusValue(String value) {
    final normalized = value.trim().toLowerCase().replaceAll('-', '_');
    return switch (normalized) {
      '' => '-',
      'true' => isChinese ? '是' : 'Yes',
      'false' => isChinese ? '否' : 'No',
      'ok' || 'healthy' || 'ready' => isChinese ? '正常' : 'Ready',
      'verified' => isChinese ? '已验证' : 'Verified',
      'unverified' => unverifiedCapabilities,
      'partial' => isChinese ? '部分就绪' : 'Partial',
      'failed' || 'fail' => isChinese ? '失败' : 'Failed',
      'enabled' => isChinese ? '已启用' : 'Enabled',
      'disabled' => isChinese ? '已禁用' : 'Disabled',
      'available' => isChinese ? '可用' : 'Available',
      'unavailable' => isChinese ? '不可用' : 'Unavailable',
      'unsupported' => isChinese ? '不支持' : 'Unsupported',
      'configured' => configured,
      'not_configured' => notConfigured,
      'detected' => detected,
      'manual' => manual,
      'trusted' => isChinese ? '已信任' : 'Trusted',
      'untrusted' => isChinese ? '未信任' : 'Untrusted',
      'allowed' || 'allow' => isChinese ? '允许' : 'Allowed',
      'denied' || 'deny' => isChinese ? '拒绝' : 'Denied',
      'blocked' => isChinese ? '已阻止' : 'Blocked',
      'pending' || 'waiting' => waiting,
      'paired' => paired,
      'active' => active,
      'inactive' => isChinese ? '未激活' : 'Inactive',
      'running' => isChinese ? '运行中' : 'Running',
      'stopped' => isChinese ? '已停止' : 'Stopped',
      _ => value,
    };
  }
}
