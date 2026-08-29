import 'package:licoup/src/contracts/presentation/layout_selection.dart';
import 'package:licoup/src/frontend/l10n/lico_strings_base.dart';

extension LicoStringsLabels on LicoStrings {
  // Shared interface actions and labels.
  String get clearSearch => isChinese ? '清除搜索' : 'Clear search';
  String get details => isChinese ? '详情' : 'Details';
  String defaultValueDisplay(String value) =>
      isChinese ? '$value（默认）' : '$value (default)';
  String get defaultModelUnavailable =>
      isChinese ? '未检测到默认模型' : 'Default model not detected';
  String get reasoningSetting => isChinese ? '思考' : 'Reasoning';
  String get workingDirectory => isChinese ? '工作目录' : 'Working directory';
  String get chooseWorkingDirectory =>
      isChinese ? '选择工作目录' : 'Choose working directory';
  String get changeWorkingDirectory =>
      isChinese ? '更改工作目录' : 'Change working directory';
  String get workingDirectoryFixedForSession => isChinese
      ? '工作目录由当前原生会话固定；新建对话后可重新选择。'
      : 'The current native session fixes its working directory. Start a new conversation to choose another.';
  String get appearance => isChinese ? '外观' : 'Appearance';
  String get network => isChinese ? '网络' : 'Network';
  String get storageAndData => isChinese ? '存储与数据' : 'Storage & Data';
  String get diagnostics => isChinese ? '诊断' : 'Diagnostics';
  String get resourceUsage => isChinese ? '资源占用' : 'Resource Usage';
  String get resourceUsageUnsupported => isChinese
      ? '当前平台不支持进程资源统计。'
      : 'Process resource statistics are not supported on this platform.';
  String get memoryUsage => isChinese ? '内存占用' : 'Memory';
  String memoryOfTotal(String total) =>
      isChinese ? '/ $total 本机内存' : 'of $total machine';
  String get systemConfiguration => isChinese ? '系统配置' : 'System';
  String get clientUpdate => isChinese ? '客户端更新' : 'Client Update';
  String get clientUpdateHint => isChinese
      ? '从 GitHub 发布源检测并安装已签名的公开更新。不需要商店账号。'
      : 'Detect and install signed public updates from the GitHub release source. No store account required.';
  String get checkUpdate => isChinese ? '检查更新' : 'Check Update';
  String get downloadToLocal => isChinese ? '下载到本地' : 'Download to local';
  String get updateAndRestart => isChinese ? '更新并重启' : 'Update and Restart';
  String get updateSource => isChinese ? '更新源' : 'Source';
  String get updateSourceGithub => isChinese ? 'GitHub 发布源' : 'GitHub releases';
  String get sourceAddress => isChinese ? '源地址' : 'Source address';
  String get channel => isChinese ? '通道' : 'Channel';
  String get availableVersion => isChinese ? '可用版本' : 'Available Version';
  String get digest => isChinese ? '摘要' : 'Digest';
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
  String get tokenUsageWindow =>
      isChinese ? 'Token 用量时间窗口' : 'Token usage window';
  String lastDays(int days) => isChinese ? '最近 $days 天' : 'Last $days days';
  String daysShort(int days) => isChinese ? '$days 天' : '${days}d';
  String get customDaysHint => isChinese ? '自定义天数' : 'Custom days';
  String get byAgent => isChinese ? '智能体' : 'By Agent';
  String get byModel => isChinese ? '模型' : 'By Model';
  String get byWorkflow => isChinese ? '工作流' : 'Workflow';
  String get workflowUsage => isChinese ? '工作流用量' : 'Workflow Usage';
  String get workflowRuns => isChinese ? '图运行' : 'Graph runs';
  String get workflowCommands => isChinese ? '图命令' : 'Graph commands';
  String get workflowTotal => isChinese ? '工作流总计' : 'Workflow total';
  String get workflowCachedInput => isChinese ? '缓存输入' : 'Cached input';
  String get workflowPrompt => isChinese ? '提示词' : 'Prompt';
  String get workflowCompletion => isChinese ? '补全' : 'Completion';
  String get workflowExactCoverage => isChinese ? '精确覆盖率' : 'Exact coverage';
  String workflowCoverage(int exact, int total, int percent) => isChinese
      ? '精确 $exact/$total（$percent%）'
      : 'Exact $exact/$total ($percent%)';
  String workflowRunLabel(int ordinal) =>
      isChinese ? '图运行 $ordinal' : 'Graph run $ordinal';
  String workflowRevisionLabel(String value) =>
      isChinese ? '修订 · $value' : 'Revision · $value';
  String workflowCommandLabel(int ordinal) =>
      isChinese ? '命令 $ordinal' : 'Command $ordinal';
  String workflowMembershipLabel(String value) =>
      isChinese ? '成员资格 · $value' : 'Membership · $value';
  String workflowAgentLabel(String value) =>
      isChinese ? '智能体 · $value' : 'Agent · $value';
  String workflowModelLabel(String value) =>
      isChinese ? '模型 · $value' : 'Model · $value';
  String workflowKindLabel(String value) {
    final normalized = value.trim().toLowerCase();
    return switch (normalized) {
      'authorization' => isChinese ? '授权' : 'Authorization',
      'actor' => isChinese ? '参与者' : 'Actor',
      'script' => isChinese ? '脚本' : 'Script',
      'workset-item' => isChinese ? '工作集项' : 'Workset item',
      _ => isChinese ? '未知类型' : 'Unknown kind',
    };
  }

  String workflowStatusLabel(String value) {
    final normalized = value.trim().toLowerCase();
    return switch (normalized) {
      'active' || 'pending' => isChinese ? '进行中' : 'Pending',
      'completed' || 'complete' => isChinese ? '已完成' : 'Completed',
      'failed' => isChinese ? '失败' : 'Failed',
      'cancelled' || 'canceled' => isChinese ? '已取消' : 'Cancelled',
      'in_doubt' || 'indoubt' => isChinese ? '待核对' : 'In doubt',
      'ready' || 'settled' => isChinese ? '已结算' : 'Settled',
      _ => isChinese ? '未知状态' : 'Unknown status',
    };
  }

  String get noWorkflowUsage => isChinese ? '暂无工作流用量' : 'No workflow usage yet';
  String get workflowUnavailable =>
      isChinese ? '工作流报表暂不可用' : 'Workflow report unavailable';
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
      'Agent tabs' => '智能体标签页',
      'Agent usage' => '智能体用量',
      'Appearance' => '外观',
      'Client logs' => '客户端日志',
      'Conversation archive' => '对话归档',
      'Error' => '错误',
      'LicoUp client' => '客户端',
      'Mobile agents' => '移动端智能体',
      'Mobile relay' => '移动中转',
      'Project archive' => '项目归档',
      'Ready' => '就绪',
      'Runtime' => '运行时',
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
      ? '查看本机智能体已有技能，或将选中技能移入系统废纸篓。'
      : 'Inspect skills already present for local agents or move one to system Trash.';
  String get refreshSkills => isChinese ? '刷新技能' : 'Refresh Skills';
  String get showSkillHubSettings =>
      isChinese ? '显示技能设置' : 'Show Skill Settings';
  String get hideSkillHubSettings =>
      isChinese ? '隐藏技能设置' : 'Hide Skill Settings';
  String get allSkills => isChinese ? '全部技能' : 'All Skills';
  String get publicSkills => isChinese ? '公共技能' : 'Public Skills';
  String get privateSkills => isChinese ? '私有技能' : 'Private Skills';
  String get skillHubSearchHint => isChinese ? '搜索技能' : 'Search skills';
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
  String get welcome => isChinese ? '欢迎' : 'Welcome';
  String get mobileAppPairing => isChinese ? '移动 App 配对' : 'Pair Mobile App';
  String get welcomeNewGroupConversation =>
      isChinese ? '新群聊' : 'New Group Chat';

  String get target => isChinese ? '目标' : 'Target';
  String get configPath => isChinese ? '配置路径' : 'Config path';
  String get binaryPath => isChinese ? '程序路径' : 'Binary path';
  String get historyRoot => isChinese ? '历史目录' : 'History root';
  String get targetLocation => isChinese ? '运行位置' : 'Runtime location';
  String get localMachine => isChinese ? '本机' : 'Local machine';
  String get virtualMachine => isChinese ? '虚拟机（SSH）' : 'Virtual machine (SSH)';
  String get virtualMachineHost => isChinese ? '虚拟机主机名或 IP' : 'VM host or IP';
  String get sshPort => isChinese ? 'SSH 端口（可选）' : 'SSH port (optional)';
  String get sshUser => isChinese ? 'SSH 用户（可选）' : 'SSH user (optional)';
  String get remoteExecutable => isChinese ? '虚拟机内程序路径' : 'Executable in VM';
  String get remoteWorkingDirectory =>
      isChinese ? '虚拟机内工作目录' : 'Working directory in VM';
  String virtualMachineDestination(String destination) => isChinese
      ? '虚拟机对话目标：$destination'
      : 'Virtual machine conversation destination: $destination';
  String get fieldRequired => isChinese ? '此项必填' : 'This field is required';
  String get invalidSshValue =>
      isChinese ? '请输入有效的 SSH 参数' : 'Enter a valid SSH value';
  String get absoluteGuestPathRequired => isChinese
      ? '请输入以 / 开头的虚拟机绝对路径'
      : 'Enter an absolute VM path beginning with /';
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
  String get conversationListNav => isChinese ? '对话' : 'Chats';
  String get skillsNav => isChinese ? '技能' : 'Skills';
  String get pluginsNav => isChinese ? '插件' : 'Plugins';
  String get adaptationDeep => isChinese ? '深度适配' : 'Deep';
  String get adaptationPartial => isChinese ? '部分适配' : 'Partial';
  String get adaptationPending => isChinese ? '待评估' : 'Pending';
  String get agentHubInstalled => isChinese ? '已安装' : 'Installed';
  String get agentHubNotInstalled => isChinese ? '未安装' : 'Not installed';
  String get agentHubExternal => isChinese ? '外部安装' : 'External';
  String get agentHubFailed => isChinese ? '失败' : 'Failed';
  String get agentHubCatalogFailed =>
      isChinese ? '无法加载智能体目录' : 'Unable to load agent catalog';
  String get agentHubVisit => isChinese ? '访问' : 'Visit →';
  String get agentHubVisitFailed =>
      isChinese ? '无法打开主页' : 'Unable to open homepage';
  String get agentHubUpdate => isChinese ? '更新' : 'Update';
  String get agentHubOpen => isChinese ? '对话' : 'Chat';
  String get agentHubBack => isChinese ? '返回' : 'Back';
  String get agentHubUninstall => isChinese ? '卸载' : 'Uninstall';
  String get mobileNav => isChinese ? '移动' : 'Mobile';
  String get statsNav => isChinese ? '统计' : 'Stats';
  String get statsPanel => isChinese ? '统计面板' : 'Statistics';
  String get newConversation => isChinese ? '新对话' : 'New Chat';
  String get createConversation => isChinese ? '新建' : 'New';
  String get newGroupConversation => isChinese ? '新群组' : 'New Group';
  String get recycleBin => isChinese ? '回收站' : 'Recycle Bin';
  String get archivedConversations => isChinese ? '归档' : 'Archived';
  String get archivedConversationsTitle =>
      isChinese ? '已归档对话' : 'Archived conversations';
  String get searchArchivedConversations =>
      isChinese ? '搜索已归档对话' : 'Search archived conversations';
  String get archivedConversationsHint => isChinese
      ? '恢复后，对话会重新出现在主列表。'
      : 'Restored conversations return to the main list.';
  String get noArchivedConversations =>
      isChinese ? '没有已归档对话' : 'No archived conversations';
  String get noMatchingArchivedConversations =>
      isChinese ? '没有匹配的已归档对话' : 'No matching archived conversations';
  String conversationRestored(String title) =>
      isChinese ? '已恢复“$title”。' : 'Restored “$title”.';
  String archivedConversationFailure(String stage, String code) => isChinese
      ? '归档对话操作失败（$stage：$code）'
      : 'Archived conversation operation failed ($stage: $code)';
  String get retry => isChinese ? '重试' : 'Retry';
  String get recentConversations => isChinese ? '最近对话' : 'Recent conversations';
  String get noConversationsYet => isChinese ? '还没有对话' : 'No conversations yet';
  String get noTrashedConversations =>
      isChinese ? '回收站为空' : 'Recycle bin is empty';
  String get delete => isChinese ? '删除' : 'Delete';
  String get deleteSkillTitle => isChinese ? '删除这个技能？' : 'Delete this skill?';
  String trashSkillMessage(String title) => isChinese
      ? '“$title” 将移入系统回收站，可在回收站中恢复。'
      : '"$title" will move to the system trash, where it can be restored.';
  String get moveToSystemTrash => isChinese ? '移入回收站' : 'Move to Trash';
  String skillMovedToSystemTrash(String title) =>
      isChinese ? '已将“$title”移入系统回收站。' : 'Moved "$title" to the system trash.';
  String get skillTrashFailed => isChinese
      ? '无法将技能移入系统回收站，请确认技能仍存在且路径可访问。'
      : 'Could not move the skill to the system trash. Check that it still exists and is accessible.';
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
  String get scrollToLatestMessages => isChinese ? '跳到最新消息' : 'Jump to latest';

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
  String subagentSteps(int count) =>
      isChinese ? '$count 步' : '$count ${count == 1 ? 'step' : 'steps'}';
  String subagentToolCalls(int count) => isChinese
      ? '$count 次工具调用'
      : '$count tool ${count == 1 ? 'call' : 'calls'}';
  String subagentNestedTasks(int count) => isChinese
      ? '$count 个子任务'
      : '$count nested ${count == 1 ? 'task' : 'tasks'}';
  String get agentProcess => isChinese ? '智能体过程' : 'Agent process';
  String get runtimeUpdateTitle => isChinese
      ? 'Cursor Agent 正在自动更新'
      : 'Cursor Agent is updating automatically';
  String get runtimeUpdateCompleted => isChinese ? '更新完成' : 'Update completed';
  String get runtimeUpdateInterrupted =>
      isChinese ? '更新中断' : 'Update interrupted';
  String get runtimeUpdateStaleLockHint =>
      isChinese ? '已清理过期安装锁' : 'Stale install lock removed';
  String get workedBriefly => isChinese ? '少于 1 秒' : 'Under 1s';
  String get reasoningProcess => isChinese ? '思考过程' : 'Reasoning';
  String get toolExecution => isChinese ? '工具执行' : 'Tool activity';
  String get agentActivity => isChinese ? '智能体活动' : 'Agent activity';
  String get runtimeLog => isChinese ? '运行记录' : 'Runtime log';
  String runtimeLogEntries(int count) => isChinese
      ? '运行记录 · $count 条'
      : 'Runtime log · $count ${count == 1 ? 'entry' : 'entries'}';
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

  // Messaging presentation (participant flow, details panel).
  String get agentBadge => 'AGENT';
  String get assistantBadge => 'ASSISTANT';
  String get subagentBadge => 'SUBAGENT';
  String get assistantActiveTooltip =>
      isChinese ? '暂停 Assistant 的后续派发' : 'Pause future Assistant dispatch';
  String get assistantPausedTooltip =>
      isChinese ? '激活 Assistant' : 'Activate Assistant';
  String get configureAssistantTooltip =>
      isChinese ? '配置 Assistant' : 'Configure Assistant';
  String get assistantProfileTitle =>
      isChinese ? 'Assistant 配置' : 'Assistant profile';
  String get assistantPausedStatus =>
      isChinese ? '你的助手已暂停' : 'Your Assistant is paused';
  String get assistantNeedsConfigurationStatus =>
      isChinese ? '配置你的助手' : 'Configure your Assistant';
  String get assistantWorkingAloneStatus =>
      isChinese ? '你的助手正在独自工作' : 'Your Assistant is working independently';
  String assistantCoordinatingStatus(int count) => isChinese
      ? '你的助手正在协调 $count 个 Subagents'
      : 'Your Assistant is coordinating $count ${count == 1 ? 'Subagent' : 'Subagents'}';
  String get assistantActionsTooltip =>
      isChinese ? '助手操作' : 'Assistant actions';
  String get newAssistantConversation =>
      isChinese ? '新助手对话' : 'New Assistant conversation';
  String get discardPendingImages =>
      isChinese ? '丢弃待发送的图片' : 'Discard pending images';
  String get contacts => isChinese ? '对话' : 'Conversations';
  String get conversationBack => isChinese ? '返回上一级' : 'Back one level';
  String mentionAgent(String agent) =>
      isChinese ? '@ $agent' : 'Mention $agent';
  String openAgentConversations(String agent) =>
      isChinese ? '打开 $agent 的对话' : 'Open $agent conversations';
  String get automaticAdaptation => isChinese ? '自动适配' : 'Automatic adaptation';
  String get noAuthorizedStrategies =>
      isChinese ? '没有已授权的策略' : 'No authorized strategies';
  String get exitStrategyMode => isChinese ? '退出策略模式' : 'Exit strategy mode';
  String get groupConversation => isChinese ? '群聊' : 'Group';
  String get groupConversationName => isChinese ? '群聊名称' : 'Group name';
  String get createGroupConversation => isChinese ? '创建' : 'Create';
  String get selectGroupConversationAgents =>
      isChinese ? '选择至少一个 Agent' : 'Select at least one Agent';
  String get groupConversationNeedsAgent => isChinese
      ? '至少需要一个可用 Agent 才能创建群聊。'
      : 'At least one available Agent is required.';
  String get noGroupConversationsYet => isChinese ? '还没有群聊' : 'No groups yet';
  String groupConversationMemberCount(int count) =>
      isChinese ? '$count 位成员' : '$count members';
  String get groupConversationMembershipChangeTitle =>
      isChinese ? '群成员变更' : 'Group membership change';
  String get groupConversationAvailabilityChangeTitle =>
      isChinese ? '成员状态变更' : 'Member status change';
  String groupConversationMemberJoined(String member) =>
      isChinese ? '新增成员：$member' : 'Added member: $member';
  String groupConversationMemberLeft(String member) =>
      isChinese ? '移除成员：$member' : 'Removed member: $member';
  String groupConversationMemberAccessSet(String member, String access) =>
      isChinese
      ? '权限变更：$member → $access'
      : 'Access changed: $member → $access';
  String groupConversationMemberAvailabilitySet(
    String member,
    String availability,
  ) => isChinese
      ? '可用状态：$member → $availability'
      : 'Availability: $member → $availability';
  String groupConversationMemberChangeUnknown(String member) =>
      isChinese ? '成员记录已变更：$member' : 'Member record changed: $member';
  String get groupConversationEventDetailsUnavailable => isChinese
      ? '旧记录未保存具体变更'
      : 'This older record does not include change details';
  String get groupConversationUnknownMember =>
      isChinese ? '未知成员' : 'Unknown member';
  String groupConversationAccessLabel(String value) => switch (value.trim()) {
    'owner' => isChinese ? '群主' : 'Owner',
    'member' => isChinese ? '成员' : 'Member',
    final normalized when normalized.isNotEmpty => normalized,
    _ => isChinese ? '未知权限' : 'Unknown access',
  };
  String groupConversationAvailabilityLabel(String value) =>
      switch (value.trim()) {
        'available' => isChinese ? '可用' : 'Available',
        'unavailable' => isChinese ? '不可用' : 'Unavailable',
        final normalized when normalized.isNotEmpty => normalized,
        _ => isChinese ? '未知状态' : 'Unknown status',
      };
  String groupConversationFailure(String stage, String code) => isChinese
      ? '群聊操作失败（$stage：$code）'
      : 'Group conversation failed ($stage: $code)';
  String groupConversationFailureCapsule(String failureRef) => isChinese
      ? '群聊操作失败 · $failureRef'
      : 'Group conversation failed · $failureRef';
  String quotaUsageCardTitle(String provider) =>
      isChinese ? '$provider 配额用量' : '$provider quota usage';
  String quotaWindowResetCountdown(String duration) =>
      isChinese ? '$duration后重置' : 'Resets in $duration';
  String quotaSnapshotCapturedAgo(String duration) =>
      isChinese ? '数据捕获于$duration前' : 'Captured $duration ago';
  String get quotaDurationUnderMinute => isChinese ? '不到 1 分钟' : '<1 min';
  String quotaDurationMinutes(int minutes) =>
      isChinese ? '$minutes 分钟' : '${minutes}m';
  String quotaDurationHoursMinutes(int hours, int minutes) =>
      isChinese ? '$hours 小时 $minutes 分钟' : '${hours}h ${minutes}m';
  String quotaDurationDaysHours(int days, int hours) =>
      isChinese ? '$days 天 $hours 小时' : '${days}d ${hours}h';
  String groupConversationFailureDetail(String stage, String code) =>
      '$stage · $code';
  String get copyFailureReport => isChinese ? '复制报错' : 'Copy error';
  String get attachments => isChinese ? '附件' : 'Attachments';
  String get imageAttachment => isChinese ? '图片' : 'Image';
  String get imageUnavailable => isChinese ? '图片不可用' : 'Image unavailable';
  String get localUser => isChinese ? '本地用户' : 'Local User';
  String get appearanceAndLayout => isChinese ? '外观与布局' : 'Appearance & Layout';
  String get notifications => isChinese ? '通知' : 'Notifications';
  String get noNotifications => isChinese ? '暂无通知' : 'No notifications';
  String skillInvocationsCount(int count) => isChinese
      ? '$count 次调用'
      : '$count ${count == 1 ? 'invocation' : 'invocations'}';
  String get allTimeInvocations => isChinese ? '累计调用' : 'All-time invocations';
  String get today => isChinese ? '今天' : 'Today';
  String get yesterday => isChinese ? '昨天' : 'Yesterday';
  String get earlier => isChinese ? '更早' : 'Earlier';
  String get priority => isChinese ? '优先' : 'Priority';

  /// Full localized weekday name for the sidebar time groups.
  /// [weekday] follows [DateTime.weekday]: 1 is Monday, 7 is Sunday.
  String conversationWeekdayLabel(int weekday) {
    const chinese = ['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'];
    const english = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    final index = (weekday - 1).clamp(0, 6);
    return isChinese ? chinese[index] : english[index];
  }

  String get working => isChinese ? '正在工作…' : 'Working…';
  String get lifecycleSubmitted => isChinese ? '消息已发送' : 'Message sent';
  String get lifecycleAccepted => isChinese ? '智能体已接收' : 'Agent received';
  String get lifecycleProcessing => isChinese ? '智能体处理中' : 'Agent is working';
  String get lifecycleResponding => isChinese ? '正在生成回复' : 'Writing response';
  String get lifecycleCompleted => isChinese ? '回复已完成' : 'Response complete';
  String get lifecycleFailed => isChinese ? '处理失败' : 'Processing failed';
  String get lifecycleSubmittedShort => isChinese ? '已发送' : 'Sent';
  String get lifecycleAcceptedShort => isChinese ? '已接收' : 'Received';
  String get lifecycleProcessingShort => isChinese ? '处理' : 'Working';
  String get lifecycleRespondingShort => isChinese ? '回复中' : 'Replying';
  String get lifecycleCompletedShort => isChinese ? '完成' : 'Done';
  String lifecycleObserved(int count, int total) =>
      isChinese ? '已观测 $count/$total 个阶段' : '$count of $total stages observed';
  String get messagingEmptyConversationGuide => isChinese
      ? '选择一个对话，或开始一个新对话'
      : 'Select a conversation or start a new one';
  String get runtimeSection => isChinese ? '运行时' : 'Runtime';
  String get capabilitiesSection => isChinese ? '能力' : 'Capabilities';
  String get connectionSection => isChinese ? '连接' : 'Connection';
  String get sessionSection => isChinese ? '会话' : 'Session';
  String get messages => isChinese ? '消息' : 'Messages';
  String get createdTime => isChinese ? '创建时间' : 'Created';
  String get showDetails => isChinese ? '显示详情' : 'Show details';
  String get hideDetails => isChinese ? '隐藏详情' : 'Hide details';

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
  String get fastModeLabel => 'Fast';
  String get currentConversation => isChinese ? '当前对话' : 'Current Conversation';
  String get addDailyConversationAgent => isChinese ? '添加智能体' : 'Add agent';
  String get confirmDailyConversationSelection =>
      isChinese ? '确认添加' : 'Confirm';
  String get noModelsFound => isChinese ? '未发现模型' : 'No Models Found';
  String get modelSearchHint => isChinese ? '搜索模型' : 'Search models';
  String get discoveringModels => isChinese ? '正在发现模型…' : 'Discovering models…';
  String get noAgentsFound => isChinese ? '未发现智能体' : 'No Agents Found';
  String get noReasoningEffortsFound =>
      isChinese ? '未发现思考强度' : 'No Reasoning Efforts Found';
  String get defaultPolicy => isChinese ? '默认策略' : 'Default Policy';
  String get agentModeLabel => isChinese ? 'Agent' : 'Agent';
  String get planModeLabel => isChinese ? 'Plan' : 'Plan';
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
      'antigravity_auth_required' =>
        isChinese
            ? '发送前需要完成 Google 账号授权。'
            : 'Google account authorization is required before sending.',
      _ => isChinese ? '操作不可用：$code' : 'Operation unavailable: $code',
    };
  }

  String messageTarget(String targetLabel) =>
      isChinese ? '发送给 $targetLabel' : 'Message $targetLabel';
  String get send => isChinese ? '发送' : 'Send';
  String conversationSendFailed(String reason) =>
      isChinese ? '发送失败：$reason' : 'Send failed: $reason';
  String get conversationAuthorizeRuntimeAction =>
      isChinese ? '授权' : 'Authorize';
  String get conversationAuthorizingRuntimeAction =>
      isChinese ? '授权中…' : 'Authorizing…';
  String conversationPermissionDenied(String tool) => isChinese
      ? '$tool 的权限请求被拒绝，回复中未执行该操作。'
      : '$tool was denied permission; the action was not performed.';
  String get conversationPermissionAllowAction => isChinese ? '允许' : 'Allow';
  String get conversationPermissionAllowAndRememberAction =>
      isChinese ? '允许并加入白名单' : 'Allow and remember';
  String get conversationPermissionDenyAction => isChinese ? '拒绝' : 'Deny';

  String get llmGatewayStart => isChinese ? '启动' : 'Start';
  String get llmGatewayStarting => isChinese ? '启动中…' : 'Starting…';
  String get llmGatewayStop => isChinese ? '停止' : 'Stop';
  String get llmGatewayStarted =>
      isChinese ? 'Gateway 已启动。' : 'Gateway started.';
  String get llmGatewayStartFailed =>
      isChinese ? 'Gateway 启动失败。' : 'Gateway failed to start.';
  String get llmGatewayStopped =>
      isChinese ? 'Gateway 已停止。' : 'Gateway stopped.';
  String get llmGatewayStopFailed =>
      isChinese ? 'Gateway 停止失败。' : 'Gateway failed to stop.';
  String get llmGatewayNotReadyWaitingForAuthorization => isChinese
      ? '尚未就绪，点击授权并启动以加载 API Key'
      : 'Not ready; authorize and start to load API keys';
  String get llmGatewayKeysLoadedStartToApply => isChinese
      ? 'API Key 已加载，点击启动应用到 Gateway'
      : 'API keys loaded; start to apply them';
  String get llmGatewayKeysLoadedWaitingForService =>
      isChinese ? 'API Key 已加载，等待服务启动' : 'API keys loaded; waiting for service';

  String get appearanceDayNight => isChinese ? '明暗模式' : 'Brightness';
  String get appearanceDay => isChinese ? '明亮' : 'Light';
  String get appearanceNight => isChinese ? '暗黑' : 'Dark';
  String get appearancePreset => isChinese ? '外观预设' : 'Appearance Preset';
  String get layoutProfile => isChinese ? '界面布局' : 'Interface Layout';
  String get layoutProfileDescription => isChinese
      ? '选择整套组件风格、页面排布与交互外观。'
      : 'Choose a complete component, arrangement, and interaction system.';
  String get layoutLoading => isChinese ? '正在加载布局…' : 'Loading layouts…';
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
  };

  String get appearancePresetDirectory =>
      isChinese ? '外观预设目录' : 'Appearance Preset Directory';
  String get reloadPresets => isChinese ? '重新加载预设' : 'Reload Presets';
  String invalidPresetConfigs(int count) =>
      isChinese ? '$count 个外观预设配置无效' : '$count invalid preset configs';
  String get portableData =>
      isChinese ? 'LicoUp 数据目录' : 'LicoUp Data Directory';
  String get clientLogs => isChinese ? '客户端日志' : 'Client Logs';
  String get exportLogs => isChinese ? '导出日志' : 'Export Logs';
  String get exportLogsDescription => '';
  String get exportingLogs => isChinese ? '正在导出日志...' : 'Exporting logs...';
  String get conversationArchiveRoot =>
      isChinese ? 'LicoUp 备份目录' : 'LicoUp Backup Directory';
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
  String get station => isChinese ? '中转站' : 'Station';
  String get saveStation => isChinese ? '保存中转站' : 'Save Station';
  String get defaultLabel => isChinese ? 'Lico' : 'Lico';
  String get planDocumentTitle => isChinese ? '计划文档' : 'Plan document';
  String get planDocumentEmpty =>
      isChinese ? '尚未写入计划内容。' : 'No plan content yet.';
  String get planDocumentUnavailable =>
      isChinese ? '无法读取计划文件。' : 'The plan file could not be read.';
  String get active => isChinese ? '当前' : 'Active';
  String get pairing => isChinese ? '通信' : 'Communication';
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
      ? '点击右上角扫描按钮，扫描 Mac 上的 LicoUp 配对二维码。'
      : 'Tap the scan button in the top-right corner to scan the LicoUp pairing QR code on your Mac.';
  String get close => isChinese ? '关闭' : 'Close';
  String get scanQrToPairPhone =>
      isChinese ? '扫描此二维码完成手机配对' : 'Scan This QR Code To Pair Your Phone';
  String get status => isChinese ? '状态' : 'Status';
  String get model => isChinese ? '模型' : 'Model';
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

  String get conversationId => isChinese ? '会话 ID' : 'Conversation ID';
  String get conversationIdCopied =>
      isChinese ? '会话 ID 已复制' : 'Conversation ID copied';
  String get conversationCopyMessage => isChinese ? '复制消息' : 'Copy message';
  String get conversationMessageCopied =>
      isChinese ? '消息已复制' : 'Message copied';
  String get edit => isChinese ? '编辑' : 'Edit';
  String get llmGatewayLaunchAtLogin => isChinese ? '开机自启动' : 'Launch at login';
  String get llmGatewayLaunchAtLoginDisabled =>
      isChinese ? '已关闭开机自启动。' : 'Launch at login disabled.';
  String get llmGatewayLaunchAtLoginEnabled =>
      isChinese ? '已开启开机自启动。' : 'Launch at login enabled.';
  String get llmGatewayLaunchAtLoginFailed =>
      isChinese ? '开机自启动未能更新。' : 'Launch at login could not be updated.';
  String get llmGatewayLaunchAtLoginHint => isChinese
      ? '登录后单独启动 Gateway（不加载 API Key；授权仍在应用内完成）'
      : 'Start the Gateway alone after login (no API keys; authorize in the app)';
  String get llmGatewayLaunchAtLoginUnsupported => isChinese
      ? '当前系统不支持 Gateway 开机自启动。'
      : 'Launch at login is not supported on this system.';
  String get startupAutostartHint => isChinese
      ? '登录后自动启动桌面客户端与可选后台进程；Gateway 启动时不加载 API Key。'
      : 'Start the desktop client and optional helpers at login. Gateway starts without API keys.';
  String get startupAutostartLoadFailed =>
      isChinese ? '无法读取自启动状态。' : 'Could not load auto-start status.';
  String get startupAutostartSaveFailed =>
      isChinese ? '自启动设置未能更新。' : 'Auto-start settings could not be updated.';
  String get startupAutostartSaved =>
      isChinese ? '自启动设置已保存。' : 'Auto-start settings saved.';
  String get startupAutostartTitle => isChinese ? '开启自启动' : 'Enable auto-start';
  String get startupAutostartUnsupported => isChinese
      ? '当前系统不支持登录自启动。'
      : 'Login auto-start is not supported on this system.';
  String get startupBackgroundSection =>
      isChinese ? '后台进程' : 'Background processes';
  String get startupDesktopClientAutostart =>
      isChinese ? '登录时启动桌面客户端' : 'Launch desktop client at login';
  String get startupDesktopClientSection =>
      isChinese ? '桌面客户端' : 'Desktop client';
  String get startupGatewayHint => isChinese
      ? '登录后单独启动 Gateway（不加载 API Key；授权仍在应用内完成）'
      : 'Start the Gateway alone after login (no API keys; authorize in the app)';
  String get startupLocalMcpHint => isChinese
      ? '登录时校验打包的本地 MCP 二进制；不会静默安装智能体 MCP'
      : 'Verify packaged local MCP binaries at login; never silently install agent MCP';
  String get startupLocalMcpServices =>
      isChinese ? '本地 MCP 服务' : 'Local MCP services';
  String get startupSilentStart => isChinese ? '静默启动' : 'Silent start';
  String get startupSilentStartHint => isChinese
      ? '启动后自动最小化，不展示界面'
      : 'Start minimized without showing the window';
  String get agentHubVisitOfficial => isChinese ? '访问官网' : 'Visit site';
  String get agentHubRefresh => isChinese ? '刷新' : 'Refresh';
  String get pluginManagementRefresh =>
      isChinese ? '刷新插件目录' : 'Refresh plugin catalog';
  String get agentHubLatest => 'latest';
  String get agentHubPackageManager => isChinese ? '包管理器' : 'Package manager';
  String get agentHubVersion => isChinese ? '版本' : 'Version';
  String agentHubUninstallTypeConfirm(String name) =>
      isChinese ? '请输入 $name 以确认' : 'Type $name to confirm';
  String get agentHubInstallContinue => isChinese ? '继续' : 'Continue';
  String agentHubInstallConfirmTitle(String name) =>
      isChinese ? '确认安装 $name？' : 'Install $name?';
  String get agentHubInstallConfirmAction => isChinese ? '确认安装' : 'Install';
  String get agentHubInstallTitle => isChinese ? '安装智能体' : 'Install agent';
  String get agentHubDownloadSource => isChinese ? '下载源' : 'Download source';
  String get agentHubPendingCommand => isChinese ? '即将执行的命令' : 'Command to run';
}
