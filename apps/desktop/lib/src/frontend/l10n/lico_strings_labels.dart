part of 'package:flutter_client/src/frontend/l10n/lico_strings.dart';

extension LicoStringsLabels on LicoStrings {
  // Shared interface actions and labels.
  String get clearSearch => isChinese ? '清除搜索' : 'Clear search';
  String get details => isChinese ? '详情' : 'Details';
  String get nativeDefault => isChinese ? '原生默认值' : 'Native default';
  String get reasoningSetting => isChinese ? '思考' : 'Reasoning';
  String get appearance => isChinese ? '外观' : 'Appearance';
  String get network => isChinese ? '网络' : 'Network';
  String get storageAndData => isChinese ? '存储与数据' : 'Storage & Data';
  String get diagnostics => isChinese ? '诊断' : 'Diagnostics';
  String get done => isChinese ? '完成' : 'Done';
  String get customize => isChinese ? '自定义' : 'Customize';

  // Usage report chrome. Product and model names remain untranslated.
  String get tokenShare => isChinese ? 'Token 占比' : 'Token Share';
  String get noAgentUsageInLatestReport =>
      isChinese ? '最新报表中没有智能体用量' : 'No agent usage in the latest report';
  String get noModelUsageInLatestReport =>
      isChinese ? '最新报表中没有模型用量' : 'No model usage in the latest report';
  String get reportTotals => isChinese ? '报表汇总' : 'Report Totals';
  String get noReportTotalsAvailable =>
      isChinese ? '暂无报表汇总' : 'No report totals available';
  String get meteredTraffic => isChinese ? '计量流量' : 'Metered Traffic';
  String get estimatedHistory => isChinese ? '历史估算量' : 'Estimated History';
  String get dailyUsageBreakdownUnavailable =>
      isChinese ? '暂无每日用量明细' : 'Daily usage breakdown unavailable';
  String get noModelUsageInLatestDailyBreakdown => isChinese
      ? '最新每日明细中没有模型用量'
      : 'No model usage in the latest daily breakdown';
  String get noAgentUsageInLatestDailyBreakdown => isChinese
      ? '最新每日明细中没有智能体用量'
      : 'No agent usage in the latest daily breakdown';
  String get usageOverTime => isChinese ? '用量趋势' : 'Usage Over Time';
  String lastDays(int days) => isChinese ? '最近 $days 天' : 'Last $days days';
  String get byAgent => isChinese ? '按智能体' : 'By Agent';
  String get byModel => isChinese ? '按模型' : 'By Model';
  String dailyTokenUsage(String date) =>
      isChinese ? '$date 每日 Token 用量' : 'Daily Token Usage · $date';
  String agentCount(int count) =>
      isChinese ? '$count 个智能体' : '$count ${count == 1 ? 'agent' : 'agents'}';
  String get apiPriceEstimate => isChinese ? 'API 价格预估' : 'Estimated API Price';
  String get priceNotEstimable => isChinese ? '不可估算' : 'Unavailable';
  String get usageAndCostsApi =>
      isChinese ? '用量 / 费用 API' : 'Usage / Costs API';
  String get balanceApi => isChinese ? '余额 API' : 'Balance API';
  String get billingCloudConsole =>
      isChinese ? '账单 / 云控制台' : 'Billing / Cloud console';

  // Home feed / former control panel labels still used elsewhere.
  String get usageReport => isChinese ? '用量报表' : 'Usage report';
  String availableAgentCount(int count) => isChinese
      ? '$count 个可用智能体'
      : '$count available ${count == 1 ? 'agent' : 'agents'}';
  String get openSkillHub => isChinese ? '打开技能中心' : 'Open Skill Hub';
  String get openRuntime => isChinese ? '打开运行时' : 'Open Runtime';
  String get reply => isChinese ? '回复' : 'Reply';
  String get composePost => isChinese ? '发帖' : 'New post';
  String get composePostHint => isChinese
      ? '写点什么，或 @ 某个智能体去完成任务…'
      : 'Write something, or @ an agent to take on a task…';
  String get mentionAgents => isChinese ? '提及智能体' : 'Mention agents';
  String get postUpdate => isChinese ? '发布' : 'Post';

  // MCP plugin management.
  String get noScannedAgents => isChinese ? '没有已扫描的智能体' : 'No scanned agents';
  String scannedAgentCount(int count) =>
      isChinese ? '$count 个智能体' : '$count ${count == 1 ? 'agent' : 'agents'}';
  String get refreshTargets => isChinese ? '刷新目标' : 'Refresh targets';
  String get mcpConfig => isChinese ? 'MCP 配置' : 'MCP config';
  String get scanTargetsBeforeManagingMcp => isChinese
      ? '请先扫描目标，再管理 MCP 插件。'
      : 'Run a target scan before managing MCP plugins.';
  String get reinstall => isChinese ? '重新安装' : 'Reinstall';
  String get update => isChinese ? '更新' : 'Update';
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

  // Local runtime.
  String get enable => isChinese ? '启用' : 'Enable';
  String get running => isChinese ? '运行中' : 'Running';
  String get stopped => isChinese ? '已停止' : 'Stopped';
  String get configuration => isChinese ? '配置' : 'Configuration';
  String get sourceRepository => isChinese ? '源代码仓库' : 'Source Repository';
  String get presetConfig => isChinese ? '预设配置' : 'Preset Config';
  String get port => isChinese ? '端口' : 'Port';
  String get rebuild => isChinese ? '重新构建' : 'Rebuild';
  String get restart => isChinese ? '重新启动' : 'Restart';
  String get stop => isChinese ? '停止' : 'Stop';
  String get logs => isChinese ? '日志' : 'Logs';
  String get serverInfo => isChinese ? '服务端信息' : 'Server Information';
  String get serverUrl => isChinese ? '服务端 URL' : 'Server URL';
  String get health => isChinese ? '健康状态' : 'Health';
  String get serverId => isChinese ? '服务端 ID' : 'Server ID';
  String get paths => isChinese ? '路径' : 'Paths';
  String get dataRoot => isChinese ? '数据根目录' : 'Data Root';
  String get runtimeConfig => isChinese ? '运行时配置' : 'Runtime Config';
  String get logFile => isChinese ? '日志文件' : 'Log File';
  String get state => isChinese ? '状态' : 'State';
  String get secrets => isChinese ? '密钥' : 'Secrets';
  String get runtimeModules => isChinese ? '运行时模块' : 'Runtime Modules';
  String get modules => isChinese ? '模块' : 'Modules';
  String get noRuntimeFeatureModules => isChinese
      ? '运行时未报告任何功能模块。'
      : 'No feature modules were reported by the runtime.';
  String get runtimeModulesAvailableAfterStartup => isChinese
      ? '运行时可用后会在这里显示模块。'
      : 'Runtime modules will appear after the runtime is available.';
  String get selectRuntimeModule =>
      isChinese ? '选择一个模块以查看其功能。' : 'Select a module to inspect its functions.';
  String get warning => isChinese ? '警告' : 'Warning';
  String get moduleId => isChinese ? '模块 ID' : 'Module ID';
  String get category => isChinese ? '类别' : 'Category';
  String get packaging => isChinese ? '打包方式' : 'Packaging';
  String get availability => isChinese ? '可用性' : 'Availability';
  String get requiredLabel => isChinese ? '必需' : 'Required';
  String get optionalLabel => isChinese ? '可选' : 'Optional';
  String get platforms => isChinese ? '平台' : 'Platforms';
  String get dependencies => isChinese ? '依赖项' : 'Dependencies';
  String get noDependencies => isChinese ? '无依赖项' : 'No dependencies';
  String runtimeGroupLabel(String value) {
    final normalized = value.trim().toLowerCase();
    return switch (normalized) {
      'core' => isChinese ? '核心' : 'Core',
      'security' => isChinese ? '安全' : 'Security',
      'module-management' => isChinese ? '模块管理' : 'Module Management',
      'data-structure' => isChinese ? '数据结构' : 'Data Structure',
      'storage' => isChinese ? '存储' : 'Storage',
      'devops' => 'DevOps',
      'capabilities' => isChinese ? '能力' : 'Capabilities',
      'activity' => isChinese ? '活动' : 'Activity',
      'agent' => isChinese ? '智能体' : 'Agent',
      'agent-ingress' => isChinese ? '智能体入口' : 'Agent Ingress',
      'agents' => isChinese ? '智能体' : 'Agents',
      'client' => isChinese ? '客户端' : 'Client',
      'modules' => isChinese ? '处理模块' : 'Processing Modules',
      'knowledge' => isChinese ? '知识' : 'Knowledge',
      'connectors' => isChinese ? '连接器' : 'Connectors',
      'ingestion' => isChinese ? '摄取' : 'Ingestion',
      'industry' => isChinese ? '行业' : 'Industry',
      'embedded-server' => isChinese ? '嵌入式服务端' : 'Embedded Server',
      'mcp' => 'MCP',
      'mcp-plugins' => isChinese ? 'MCP 插件' : 'MCP Plugins',
      'mobile-relay' => isChinese ? '移动中转' : 'Mobile Relay',
      'model-forwarding' => isChinese ? '模型转发' : 'Model Forwarding',
      'settings' => isChinese ? '设置' : 'Settings',
      'skill-hub' => isChinese ? '技能中心' : 'Skill Hub',
      'runtime' => isChinese ? '运行时' : 'Runtime',
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
  String get collapseHistory => isChinese ? '收起历史' : 'Collapse history';
  String get expandHistory => isChinese ? '展开历史' : 'Expand history';
  String usagePercentage(String productName) =>
      isChinese ? '$productName 用量占比' : '$productName usage percentage';
  String get resetCredits => isChinese ? '重置次数' : 'Reset credits';
  String quotaRemaining(String model, String remaining, String reset) {
    if (isChinese) {
      final suffix = reset.isEmpty ? '' : ' · $reset 后重置';
      return '• $model · 剩余 $remaining$suffix';
    }
    final suffix = reset.isEmpty ? '' : ' · resets in $reset';
    return '• $model · $remaining left$suffix';
  }

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
      'Future client' => '客户端',
      'MCP config plan' => 'MCP 配置计划',
      'MCP plugin' => 'MCP 插件',
      'Mobile agents' => '移动端智能体',
      'Mobile relay' => '移动中转',
      'Project archive' => '项目归档',
      'Proxy Bridge' => '代理桥接',
      'Ready' => '就绪',
      'Runtime' => '运行时',
      'Secure Mesh' => '安全网格',
      'Settings' => '设置',
      'Skill Hub' => '技能中心',
      'Snapshots' => '快照',
      'Target inspect' => '目标检查',
      'Targets' => '目标',
      'Voice input' => '语音输入',
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
  String get loadable => isChinese ? '可加载' : 'Loadable';
  String get noSkillsFound => isChinese ? '未发现技能' : 'No Skills Found';
  String get refreshSkillsHint => isChinese
      ? '刷新后会重新扫描本机技能目录。'
      : 'Refresh to scan local skill directories again.';
  String get noDescription => isChinese ? '暂无描述' : 'No description';
  String get skillId => isChinese ? '技能 ID' : 'Skill ID';
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
  String get voiceInput => isChinese ? '语音输入' : 'Voice Input';
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
  String get selectAgentToView => isChinese
      ? '选择一个智能体查看历史并对话'
      : 'Select an agent to view histories and chat';

  String get target => isChinese ? '目标' : 'Target';
  String get configPath => isChinese ? '配置路径' : 'Config path';
  String get binaryPath => isChinese ? '程序路径' : 'Binary path';
  String get historyRoot => isChinese ? '历史目录' : 'History root';
  String get cancel => isChinese ? '取消' : 'Cancel';
  String get inspect => isChinese ? '查看' : 'Inspect';
  String get plan => isChinese ? '计划' : 'Plan';

  String get configured => isChinese ? '已配置' : 'Configured';
  String get detected => isChinese ? '已检测到' : 'Detected';
  String get manual => isChinese ? '手动添加' : 'Manual';
  String get unavailable => isChinese ? '不可用' : 'Unavailable';
  String get notConfigured => isChinese ? '未配置' : 'Not configured';

  String get historyConversations =>
      isChinese ? '历史对话' : 'Conversation history';
  String get historyConversationSearchHint =>
      isChinese ? '搜索历史对话' : 'Search conversations';
  String get noMatchingNativeHistories =>
      isChinese ? '没有匹配的历史对话' : 'No matching histories';
  String conversationCount(int count) =>
      isChinese ? '$count 条对话' : '$count conversations';
  String get conversations => isChinese ? '对话' : 'Conversations';
  String get newConversation => isChinese ? '新对话' : 'New Conversation';
  String get recycleBin => isChinese ? '回收站' : 'Recycle Bin';
  String get archivedConversations =>
      isChinese ? '已存档对话' : 'Archived Conversations';
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
  String messagesCount(int count) =>
      isChinese ? '$count 条消息' : '$count messages';
  String get noMessagesInHistory => isChinese ? '还没有消息' : 'No messages yet';

  String get keywords => isChinese ? '关键词' : 'Keywords';
  String get archiveDirectory => isChinese ? '归档目录' : 'Archive directory';
  String get archive => isChinese ? '归档' : 'Archive';
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
  String get conversationParityBlockedCause =>
      isChinese ? '阻断原因' : 'Blocked cause';
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
      'evidence_missing' => isChinese
          ? '缺少当前版本的对等证据，发送保持关闭。'
          : 'Current parity evidence is missing, so sending stays closed.',
      'evidence_incomplete' => isChinese
          ? '对等证据不完整，发送保持关闭。'
          : 'Parity evidence is incomplete, so sending stays closed.',
      'evidence_stale_or_incomplete' => isChinese
          ? '对等证据已过期或不完整，请重新扫描后重试。'
          : 'Parity evidence is stale or incomplete; rescan and retry.',
      'runtime_evidence_binding_mismatch' => isChinese
          ? '运行时证据绑定不匹配，请重新扫描智能体。'
          : 'Runtime evidence binding mismatch; rescan agents.',
      'official_native_lane_missing' => isChinese
          ? '缺少可公开使用的官方会话通道。'
          : 'No official public conversation lane is available.',
      'exact_session_resume_unavailable' => isChinese
          ? '无法在官方通道上精确恢复原生会话。'
          : 'Exact native session resume is unavailable on the official lane.',
      'antigravity_public_transport_unavailable' => isChinese
          ? '该适配器没有可用的公开会话传输。'
          : 'No public conversation transport is available for this adapter.',
      'native_conversation_parity_unverified' ||
      'native_conversation_parity_blocked' ||
      'native_conversation_parity_failed' ||
      'native_conversation_parity_partial' ||
      'native_conversation_parity_history-only' => isChinese
          ? '原生会话对等尚未就绪，发送保持关闭。'
          : 'Native conversation parity is not ready, so sending stays closed.',
      'orchestration_policy_required' => configurePolicyBeforeSend,
      'orchestration_targets_unavailable' => isChinese
          ? '当前策略没有可用的发送目标。'
          : 'The current policy has no available send targets.',
      _ => isChinese
          ? '发送因对等门禁关闭：$code'
          : 'Sending closed by parity gate: $code',
    };
  }
  String messageTarget(String targetLabel) =>
      isChinese ? '发送给 $targetLabel' : 'Message $targetLabel';
  String get send => isChinese ? '发送' : 'Send';

  String get appearancePreset => isChinese ? '外观方案' : 'Appearance Preset';
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
  String get assistantAgent => isChinese ? '辅助智能体' : 'Assistant Agent';
  String get assistantAgentDescription => isChinese
      ? '客户端可调用的智能体，用于执行需要智能体能力的辅助操作。'
      : 'Agent the client can call for assistant-only operations.';
  String get assistantAgentPendingSelection =>
      isChinese ? '请选择一个扫描到的智能体' : 'Choose a scanned agent';
  String get chooseAssistantAgent =>
      isChinese ? '选择辅助智能体' : 'Choose assistant agent';
  String get scanAssistantAgents => isChinese ? '扫描智能体' : 'Scan agents';
  String get noAssistantAgentsAvailable =>
      isChinese ? '扫描后会显示可用智能体' : 'Scanned agents will appear here';
  String get recommendedPlugins => isChinese ? '推荐插件' : 'Recommended Plugins';

  String get proxyBridge => isChinese ? 'Clash 代理桥接' : 'Clash Proxy Bridge';
  String get proxyBridgeDescription => isChinese
      ? '检测 Clash Verge mixed-port，让客户端流量和所选智能体 wrapper 直接走 Clash。'
      : 'Detect Clash Verge mixed-port and route client calls plus selected agent wrappers directly through Clash.';
  String get proxyBridgeDetect => isChinese ? '检测' : 'Detect';
  String get proxyBridgePlan => isChinese ? '生成计划' : 'Plan';
  String get proxyBridgeEnable => isChinese ? '启用桥接' : 'Enable Bridge';
  String get proxyBridgeDisable => isChinese ? '关闭桥接' : 'Disable Bridge';
  String get proxyBridgeEnabled => isChinese ? '已启用' : 'Enabled';
  String get proxyBridgeDisabled => isChinese ? '未启用' : 'Disabled';
  String get proxyBridgeReachable => isChinese ? '端口可达' : 'Port reachable';
  String get proxyBridgeUnreachable =>
      isChinese ? '端口未连通' : 'Port not reachable';
  String get proxyBridgeAgents => isChinese ? '桥接智能体' : 'Bridged agents';
  String get proxyBridgeTunAssist => isChinese ? 'TUN 辅助配置' : 'TUN Assist';
  String get proxyBridgeNoClashMutation => isChinese
      ? '不会静默修改 Clash 配置；TUN 片段仅用于人工审查。'
      : 'Clash config is never changed silently; the TUN snippet is advisory.';

  String get secureMesh => isChinese ? '安全网格' : 'Secure Mesh';
  String get refresh => isChinese ? '刷新' : 'Refresh';
  String get protocol => isChinese ? '协议' : 'Protocol';
  String get pairwise => isChinese ? '点对点' : 'Pairwise';
  String get file => isChinese ? '文件' : 'File';
  String get fileRoute => isChinese ? '文件路由' : 'File Route';
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
  String get privateGateway => isChinese ? '私有网关' : 'Private';
  String get gatewayLocked =>
      isChinese ? '默认 Lico Arc 网关不可编辑' : 'Default Lico Arc gateway is locked';
  String get saveGateway => isChinese ? '保存网关' : 'Save Gateway';
  String get defaultLabel => isChinese ? '默认' : 'Default';
  String get active => isChinese ? '当前' : 'Active';
  String get pairing => isChinese ? '配对' : 'Pairing';
  String get createCode => isChinese ? '创建配对码' : 'Create Code';
  String get copyPairingCode => isChinese ? '复制配对码' : 'Copy Pairing Code';
  String get pairingCodeCopied => isChinese ? '配对码已复制' : 'Pairing Code Copied';
  String get oneTimePairingCode =>
      isChinese ? '一次性配对码' : 'One-Time Pairing Code';
  String get oneTimePairingCodeNotice => isChinese
      ? '此配对码只会展示一次，关闭后会立即从本机清除。重新创建会生成全新的配对码。'
      : 'This pairing code is shown once and cleared locally when closed. Creating again generates a new code.';
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
  String get relayStatus => isChinese ? '中转状态' : 'Relay Status';
  String get pairedComputer => isChinese ? '配对电脑' : 'Paired Computer';
  String get arcDesktop => isChinese ? 'Arc Desktop' : 'Arc Desktop';
  String get availableAgents => isChinese ? '可用智能体' : 'Available Agents';
  String get desktopAgents => isChinese ? '电脑智能体' : 'Desktop Agents';
  String get secureRelay =>
      isChinese ? '通过电脑安全中转' : 'Secure Relay Through Computer';
  String get noDesktopAgents =>
      isChinese ? '这台电脑暂未回显可用智能体。' : 'No desktop agents are available yet.';
  String get handoffToDesktopAgent =>
      isChinese ? '转交给电脑智能体' : 'Hand Off To Desktop Agent';
  String get openChatGptWebConversation =>
      isChinese ? '打开 ChatGPT 网页端' : 'Open ChatGPT Web';
  String get additionalPrompt => isChinese ? '新增提示词' : 'Additional Prompt';
  String get handoff => isChinese ? '转交' : 'Hand Off';
  String get recentCommands => isChinese ? '最近命令' : 'Recent Commands';
  String get executionRecords => isChinese ? '执行记录' : 'Execution Records';
  String get authorizationRequired =>
      isChinese ? '等待授权' : 'Authorization Required';
  String get connected => isChinese ? '已连接' : 'Connected';
  String get authorized => isChinese ? '已授权' : 'Authorized';
  String get chatValidationFailed =>
      isChinese ? '对话验证失败' : 'Chat Validation Failed';
  String get added => isChinese ? '已添加' : 'Added';
  String get authorizationMethod => isChinese ? '授权方式' : 'Authorization Method';
  String get oauthPkceAuthorization => isChinese
      ? 'OAuth 2.0 / PKCE 网页授权'
      : 'OAuth 2.0 / PKCE Web Authorization';
  String oauthAuthorizationMethodForProvider(String providerId, String label) {
    final normalized = providerId.trim().toLowerCase();
    if (normalized == 'chatgpt') {
      return isChinese
          ? 'ChatGPT OAuth（网页端对话）'
          : 'ChatGPT OAuth (web conversation)';
    }
    return oauthPkceAuthorization;
  }

  String get apiKeyAuthorization => isChinese ? 'API Key 直连' : 'Direct API Key';
  String get pairedComputerAuthorization =>
      isChinese ? '配对电脑授权' : 'Paired Computer Authorization';
  String get apiKeyReady => isChinese ? 'API Key 已配置' : 'API Key Configured';
  String apiKeySyncedReady(String label) => isChinese
      ? '已授权，API Key 已从 $label 同步到手机。'
      : 'Authorized. The API key has been synced from $label to this phone.';
  String get oauthClientRequired => isChinese
      ? '需要先完成网页登录授权。'
      : 'Web sign-in authorization is required first.';
  String oauthReadyForProvider(String label) => isChinese
      ? 'OAuth 已授权，手机端可直连 $label。'
      : 'OAuth authorized. This phone can connect to $label directly.';
  String oauthReadyForProviderSurface(String providerId, String label) {
    final normalized = providerId.trim().toLowerCase();
    if (normalized == 'chatgpt') {
      return isChinese
          ? 'ChatGPT OAuth 已授权，手机端可通过 ChatGPT 网页端对话。'
          : 'ChatGPT OAuth authorized. This phone can use ChatGPT web conversation directly.';
    }
    return oauthReadyForProvider(label);
  }

  String oauthChatValidationFailedForProvider(String providerId, String label) {
    final normalized = providerId.trim().toLowerCase();
    if (normalized == 'chatgpt') {
      return isChinese
          ? 'ChatGPT OAuth 已保存，但真实对话验证失败。请重新网页授权或稍后重试。'
          : 'ChatGPT OAuth is saved, but real chat validation failed. Reauthorize or retry later.';
    }
    return isChinese
        ? '$label OAuth 已保存，但真实对话验证失败。请重新授权或稍后重试。'
        : '$label OAuth is saved, but real chat validation failed. Reauthorize or retry later.';
  }

  String get oauthReady => oauthReadyForProvider('ChatGPT');
  String get apiKeyStoredLocally => isChinese
      ? '手机端已记录授权状态；明文密钥不会写入便携配置文件。'
      : 'The phone records authorization state; the plaintext key is not written to portable config.';
  String get webAuthorization => isChinese ? '网页授权' : 'Web Authorization';
  String webAuthorizationForProvider(String providerId, String label) {
    final normalized = providerId.trim().toLowerCase();
    if (normalized == 'chatgpt') {
      return isChinese ? 'ChatGPT 网页授权' : 'ChatGPT Web Authorization';
    }
    return webAuthorization;
  }

  String get pasteOAuthCallbackUrl =>
      isChinese ? '粘贴回调链接' : 'Paste Callback URL';
  String get oauthRecoveryTitle =>
      isChinese ? 'OAuth 授权需要刷新' : 'OAuth Authorization Needs Refresh';
  String oauthRecoveryBody(String label) => isChinese
      ? '$label 拒绝了当前 OAuth 凭据。请重新完成网页授权后再继续直连对话。'
      : '$label rejected the current OAuth credential. Reauthorize in the browser before continuing direct chat.';
  String get oauthAuthorizationWaitingTitle =>
      isChinese ? '等待网页授权' : 'Waiting For Web Authorization';
  String oauthAuthorizationWaitingBody(String label) => isChinese
      ? '请在浏览器完成 $label OAuth 授权；返回 Arc 后会自动检测授权状态。'
      : 'Complete $label OAuth authorization in the browser. Arc will detect it when you return.';
  String oauthAuthorizationWaitingBodyForProvider(
    String providerId,
    String label,
  ) {
    final normalized = providerId.trim().toLowerCase();
    if (normalized == 'chatgpt') {
      return isChinese
          ? '请在浏览器完成 ChatGPT OAuth 授权；返回 Arc 后会自动检测授权状态。'
          : 'Complete ChatGPT OAuth authorization in the browser. Arc will detect it when you return.';
    }
    return oauthAuthorizationWaitingBody(label);
  }

  String get oauthAuthorizationWaitingAction => isChinese ? '等待授权中' : 'Waiting';
  String get oauthAuthorizationFailedTitle =>
      isChinese ? '授权验证失败' : 'Authorization Verification Failed';
  String oauthAuthorizationFailedBodyForProvider(
    String providerId,
    String label,
    String detail,
  ) {
    final trimmed = detail.trim();
    final suffix = trimmed.isEmpty
        ? ''
        : isChinese
        ? '：$trimmed'
        : ': $trimmed';
    final normalized = providerId.trim().toLowerCase();
    if (normalized == 'chatgpt') {
      return isChinese
          ? 'ChatGPT OAuth 已返回，但手机端真实对话验证没有通过$suffix。请重新网页授权或确认该账号有 ChatGPT 对话权限。'
          : 'ChatGPT OAuth returned, but the phone could not verify a real chat$suffix. Reauthorize or confirm this account can use ChatGPT conversations.';
    }
    return isChinese
        ? '$label OAuth 已返回，但真实对话验证没有通过$suffix。请重新授权后再继续。'
        : '$label OAuth returned, but real chat verification failed$suffix. Reauthorize before continuing.';
  }

  String get oauthAuthorizationSuccessTitle =>
      isChinese ? '授权成功' : 'Authorization Successful';
  String oauthAuthorizationSuccessBody(String label) => isChinese
      ? '$label OAuth 已授权，手机端可以直接对话。'
      : '$label OAuth is authorized. This phone can chat directly.';
  String oauthAuthorizationSuccessBodyForProvider(
    String providerId,
    String label,
  ) {
    final normalized = providerId.trim().toLowerCase();
    if (normalized == 'chatgpt') {
      return isChinese
          ? 'ChatGPT OAuth 已授权，手机端可通过 ChatGPT 网页端直连对话。'
          : 'ChatGPT OAuth is authorized. This phone can chat through ChatGPT web conversation directly.';
    }
    return oauthAuthorizationSuccessBody(label);
  }

  String get refreshSyncedOAuthAuthorization =>
      isChinese ? '重新同步授权' : 'Refresh Synced Authorization';
  String get reauthorizeOAuth => isChinese ? '重新网页授权' : 'Reauthorize';
  String get configureApiKey => isChinese ? '配置 API Key' : 'Configure API Key';
  String get apiKeyInputLabel => 'API Key';
  String get apiKeyInputHint =>
      isChinese ? '粘贴供应商 API Key' : 'Paste provider API key';
  String get saveApiKey => isChinese ? '保存 API Key' : 'Save API Key';
  String get openApiKeyPage =>
      isChinese ? '打开官方 API Key 页面' : 'Open Official API Key Page';
  String get openProviderPage => isChinese ? '打开官方页面' : 'Open Official Page';
  String get chatGptOAuthNotApiKeyNotice => isChinese
      ? 'ChatGPT / Codex 的 OAuth 登录不会生成 OpenAI Platform API Key；手机本机直连官网 API 仍需要 API Key。'
      : 'ChatGPT / Codex OAuth sign-in does not create an OpenAI Platform API key; direct on-phone OpenAI API access still requires an API key.';
  String availableThroughPairedComputer(String label) =>
      isChinese ? '通过 $label 可用' : 'Available Through $label';
  String syncedFromPairedComputer(String label) =>
      isChinese ? '已从 $label 同步到手机' : 'Synced From $label To This Phone';
  String openingProviderCredentialPage(String label) =>
      isChinese ? '正在打开 $label 官方授权页面。' : 'Opening $label authorization page.';
  String openedProviderCredentialPage(String label) =>
      isChinese ? '已打开 $label 官方授权页面。' : 'Opened $label authorization page.';
  String providerCredentialPageOpenFailed(String label) => isChinese
      ? '$label 官方授权页面打开失败。'
      : 'Failed to open $label authorization page.';
  String oauthSetupNotice(String docsUrl) => isChinese
      ? '此服务支持 OAuth，但需要先为 Lico Arc 注册 OAuth Client ID、回调 scheme 和 PKCE 流程。官方文档：$docsUrl'
      : 'This service supports OAuth, but Lico Arc still needs a registered OAuth client ID, redirect scheme, and PKCE flow. Official docs: $docsUrl';
  String apiKeySetupNotice(String docsUrl) => isChinese
      ? '此供应商支持 API Key 直连。官方文档：$docsUrl'
      : 'This provider supports direct API-key access. Official docs: $docsUrl';

  String displayStatusValue(String value) {
    final normalized = value.trim().toLowerCase().replaceAll('-', '_');
    return switch (normalized) {
      '' => '-',
      'true' => isChinese ? '是' : 'Yes',
      'false' => isChinese ? '否' : 'No',
      'ok' || 'healthy' || 'ready' => isChinese ? '正常' : 'Ready',
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
      'denied' || 'deny' || 'blocked' => isChinese ? '拒绝' : 'Denied',
      'pending' || 'waiting' => waiting,
      'paired' => paired,
      'active' => active,
      'inactive' => isChinese ? '未激活' : 'Inactive',
      'running' => isChinese ? '运行中' : 'Running',
      'stopped' => isChinese ? '已停止' : 'Stopped',
      _ => value,
    };
  }

  // Feed / 广场
  String get feedEmptyTitle =>
      isChinese ? '广场还没有更新' : 'No updates in the feed yet';
  String get feedEmptySubtitle => isChinese
      ? '智能体完成工作后会自动在这里发布更新。'
      : 'Agents will publish updates here when they finish work.';
  String get feedRefresh => isChinese ? '刷新广场' : 'Refresh feed';
  String get comments => isChinese ? '评论' : 'Comments';
  String get comment => isChinese ? '评论' : 'Comment';
  String get addComment => isChinese ? '添加评论' : 'Add comment';
  String get addCommentHint =>
      isChinese ? '写下反馈，让智能体继续工作…' : 'Write feedback for the agent…';
  String get postComment => isChinese ? '发送' : 'Post';
  String get repost => isChinese ? '转发' : 'Repost';
  String get forwardTo => isChinese ? '转发给' : 'Forward to';
  String get forward => isChinese ? '转发' : 'Forward';
  String get forwardNoteHint =>
      isChinese ? '补充说明（可选）' : 'Add a note (optional)';
  String get following => isChinese ? '关注' : 'Following';
  String get follow => isChinese ? '关注' : 'Follow';
  String get unfollow => isChinese ? '取消关注' : 'Unfollow';
  String get myAgents => isChinese ? '我的智能体' : 'My Agents';
  String get otherUsers => isChinese ? '其他用户' : 'Other Users';
  String get addToFollowing => isChinese ? '添加到关注' : 'Add to following';
  String get followingEmpty =>
      isChinese ? '还没有关注任何人' : 'Not following anyone yet';
  String get deletePost => isChinese ? '删除这条更新' : 'Delete this update';
  String get deletePostConfirm => isChinese
      ? '确定要删除这条更新吗？相关的评论和转发也会被移除。'
      : 'Delete this update? Related comments and reposts will also be removed.';
  String get agentWorking => isChinese ? '工作中' : 'Working';
  String get agentDone => isChinese ? '已完成' : 'Done';
  String get agentError => isChinese ? '出错' : 'Error';
  String get noCommentsYet => isChinese ? '还没有评论' : 'No comments yet';
  String get repostedTo => isChinese ? '已转发给' : 'Forwarded to';
  String get selectAgentToForward =>
      isChinese ? '选择要接手的智能体' : 'Select an agent to hand off to';
  String feedDurationSeconds(int seconds) =>
      isChinese ? '$seconds 秒' : '$seconds s';
  String feedDurationMinutes(int minutes, int seconds) => isChinese
      ? '$minutes 分 ${seconds > 0 ? '$seconds 秒' : ''}'
      : '$minutes m ${seconds > 0 ? '$seconds s' : ''}';
  String feedMetrics(int steps, int tokens) =>
      isChinese ? '$steps 步 · $tokens tokens' : '$steps steps · $tokens tokens';
}
