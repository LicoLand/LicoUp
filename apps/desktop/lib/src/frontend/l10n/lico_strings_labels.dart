import 'package:licoup/src/contracts/presentation/layout_selection_status.dart';
import 'package:licoup/src/frontend/l10n/lico_strings_base.dart';

extension LicoStringsLabels on LicoStrings {
  // Execution process and reply state.
  String get executionProcess =>
      localized('executionProcess', isChinese ? '执行过程' : 'Execution process');
  String get executionProcessSearch => localized(
    'executionProcessSearch',
    isChinese ? '搜索全部记录，按 Enter 跳转' : 'Search all records · Enter to jump',
  );
  String get executionProcessEmpty => localized(
    'executionProcessEmpty',
    isChinese ? '暂无执行记录' : 'No execution records yet',
  );
  String get executionProcessLoading => localized(
    'executionProcessLoading',
    isChinese ? '正在读取执行记录…' : 'Loading execution records…',
  );
  String get executionProcessPreparing => localized(
    'executionProcessPreparing',
    isChinese ? '正在准备显示…' : 'Preparing display…',
  );
  String get executionProcessUnavailable => localized(
    'executionProcessUnavailable',
    isChinese
        ? '该回复没有可用的执行记录'
        : 'Execution records are unavailable for this reply',
  );
  String get executionProcessIncomplete => localized(
    'executionProcessIncomplete',
    isChinese
        ? '历史记录不完整：该次执行的终态原文不可用'
        : 'Historical records are incomplete: the raw terminal result is unavailable.',
  );
  String get replyCompletedWithoutText => localized(
    'replyCompletedWithoutText',
    isChinese ? '已结束，未生成正文' : 'Completed without a text reply',
  );
  String get replyCancelled =>
      localized('replyCancelled', isChinese ? '已取消' : 'Cancelled');
  String get replyInterrupted =>
      localized('replyInterrupted', isChinese ? '已中断' : 'Interrupted');
  String get replyFailed =>
      localized('replyFailed', isChinese ? '回复失败' : 'Reply failed');
  String get executionProcessLatest => localized(
    'executionProcessLatest',
    isChinese ? '回到最新' : 'Back to latest',
  );
  String get executionProcessCopyRecord => localized(
    'executionProcessCopyRecord',
    isChinese ? '复制完整原始记录' : 'Copy complete raw record',
  );
  String get executionProcessPreviousMatch => localized(
    'executionProcessPreviousMatch',
    isChinese ? '上一处匹配' : 'Previous match',
  );
  String get executionProcessNextMatch => localized(
    'executionProcessNextMatch',
    isChinese ? '下一处匹配' : 'Next match',
  );
  String get executionProcessNoMatches =>
      localized('executionProcessNoMatches', isChinese ? '无匹配' : 'No matches');
  String executionProcessRecord(int number) =>
      isChinese ? '记录 $number' : 'Record $number';
  String executionProcessRecords(int count) =>
      isChinese ? '$count 条记录' : '$count records';
  String executionProcessMatches(int current, int total) => '$current / $total';

  // Shared interface actions and labels.
  String get clearSearch =>
      localized('clearSearch', isChinese ? '清除搜索' : 'Clear search');
  String get details => localized('details', isChinese ? '详情' : 'Details');
  String defaultValueDisplay(String value) =>
      isChinese ? '$value（默认）' : '$value (default)';
  String get defaultModelUnavailable => localized(
    'defaultModelUnavailable',
    isChinese ? '未检测到默认模型' : 'Default model not detected',
  );
  String get reasoningSetting =>
      localized('reasoningSetting', isChinese ? '思考' : 'Reasoning');
  String get workingDirectory =>
      localized('workingDirectory', isChinese ? '工作目录' : 'Working directory');
  String get chooseWorkingDirectory => localized(
    'chooseWorkingDirectory',
    isChinese ? '选择工作目录' : 'Choose working directory',
  );
  String get changeWorkingDirectory => localized(
    'changeWorkingDirectory',
    isChinese ? '更改工作目录' : 'Change working directory',
  );
  String get workingDirectoryFixedForSession => localized(
    'workingDirectoryFixedForSession',
    isChinese
        ? '工作目录由当前原生会话固定；新建对话后可重新选择。'
        : 'The current native session fixes its working directory. Start a new conversation to choose another.',
  );
  String get appearance =>
      localized('appearance', isChinese ? '外观' : 'Appearance');
  String get network => localized('network', isChinese ? '网络' : 'Network');
  String get storageAndData =>
      localized('storageAndData', isChinese ? '存储与数据' : 'Storage & Data');
  String get diagnostics =>
      localized('diagnostics', isChinese ? '诊断' : 'Diagnostics');
  String get resourceUsage =>
      localized('resourceUsage', isChinese ? '资源占用' : 'Resource Usage');
  String get resourceUsageUnsupported => localized(
    'resourceUsageUnsupported',
    isChinese
        ? '当前平台不支持进程资源统计。'
        : 'Process resource statistics are not supported on this platform.',
  );
  String get memoryUsage =>
      localized('memoryUsage', isChinese ? '内存占用' : 'Memory');
  String memoryOfTotal(String total) =>
      isChinese ? '/ $total 本机内存' : 'of $total machine';
  String get systemConfiguration =>
      localized('systemConfiguration', isChinese ? '系统配置' : 'System');
  String get clientUpdate =>
      localized('clientUpdate', isChinese ? '客户端更新' : 'Client Update');
  String get clientUpdateHint => localized(
    'clientUpdateHint',
    isChinese
        ? '从 GitHub 发布源检测并安装已签名的公开更新。不需要商店账号。'
        : 'Detect and install signed public updates from the GitHub release source. No store account required.',
  );
  String get checkUpdate =>
      localized('checkUpdate', isChinese ? '检查更新' : 'Check Update');
  String get downloadToLocal =>
      localized('downloadToLocal', isChinese ? '下载到本地' : 'Download to local');
  String get updateAndRestart =>
      localized('updateAndRestart', isChinese ? '更新并重启' : 'Update and Restart');
  String get updateSource =>
      localized('updateSource', isChinese ? '更新源' : 'Source');
  String get updateSourceGithub => localized(
    'updateSourceGithub',
    isChinese ? 'GitHub 发布源' : 'GitHub releases',
  );
  String get sourceAddress =>
      localized('sourceAddress', isChinese ? '源地址' : 'Source address');
  String get channel => localized('channel', isChinese ? '通道' : 'Channel');
  String get nightlyChannel =>
      localized('nightlyChannel', isChinese ? 'Nightly' : 'Nightly');
  String get stableChannel =>
      localized('stableChannel', isChinese ? '稳定版' : 'Stable');
  String get availableVersion =>
      localized('availableVersion', isChinese ? '可用版本' : 'Available Version');
  String get clientUpdateAdvanced =>
      localized('clientUpdateAdvanced', isChinese ? '高级' : 'Advanced');
  String updateAvailableNamed(String version) =>
      isChinese ? '新版本 $version 可用' : 'Version $version available';
  String get digest => localized('digest', isChinese ? '摘要' : 'Digest');
  String get done => localized('done', isChinese ? '完成' : 'Done');
  String get customize =>
      localized('customize', isChinese ? '自定义' : 'Customize');

  // Usage report chrome. Product and model names remain untranslated.
  String get usageLoading =>
      localized('usageLoading', isChinese ? '正在加载中' : 'Loading usage');
  String get usageLoadFailed => localized(
    'usageLoadFailed',
    isChinese ? '用量加载失败，请刷新重试' : 'Usage could not be loaded. Refresh to retry.',
  );
  String get noAgentUsageInLatestReport => localized(
    'noAgentUsageInLatestReport',
    isChinese ? '最新报表中没有智能体用量' : 'No agent usage in the latest report',
  );
  String get noModelUsageInLatestReport => localized(
    'noModelUsageInLatestReport',
    isChinese ? '最新报表中没有模型用量' : 'No model usage in the latest report',
  );

  /// Hosted-ledger rows whose requests carried no token fields never show a
  /// token total; they show how many requests the plan included.
  String agentUsageIncludedRequests(int count) =>
      isChinese ? '已包含 $count 次请求' : 'Included · $count requests';
  String get dailyUsageBreakdownUnavailable => localized(
    'dailyUsageBreakdownUnavailable',
    isChinese ? '暂无每日用量明细' : 'Daily usage breakdown unavailable',
  );
  String get noModelUsageInLatestDailyBreakdown => localized(
    'noModelUsageInLatestDailyBreakdown',
    isChinese
        ? '最新每日明细中没有模型用量'
        : 'No model usage in the latest daily breakdown',
  );
  String get noAgentUsageInLatestDailyBreakdown => localized(
    'noAgentUsageInLatestDailyBreakdown',
    isChinese
        ? '最新每日明细中没有智能体用量'
        : 'No agent usage in the latest daily breakdown',
  );
  String get tokenUsageWindow => localized(
    'tokenUsageWindow',
    isChinese ? 'Token 用量时间窗口' : 'Token usage window',
  );
  String lastDays(int days) => isChinese ? '最近 $days 天' : 'Last $days days';
  String daysShort(int days) => isChinese ? '$days 天' : '${days}d';
  String get customDaysHint =>
      localized('customDaysHint', isChinese ? '自定义天数' : 'Custom days');
  String get byAgent => localized('byAgent', isChinese ? '智能体' : 'By Agent');
  String get byModel => localized('byModel', isChinese ? '模型' : 'By Model');
  String get byWorkflow =>
      localized('byWorkflow', isChinese ? '工作流' : 'Workflow');
  String get workflowUsage =>
      localized('workflowUsage', isChinese ? '工作流用量' : 'Workflow Usage');
  String get workflowRuns =>
      localized('workflowRuns', isChinese ? '图运行' : 'Graph runs');
  String get workflowCommands =>
      localized('workflowCommands', isChinese ? '图命令' : 'Graph commands');
  String get workflowTotal =>
      localized('workflowTotal', isChinese ? '工作流总计' : 'Workflow total');
  String get workflowCachedInput =>
      localized('workflowCachedInput', isChinese ? '缓存输入' : 'Cached input');
  String get workflowPrompt =>
      localized('workflowPrompt', isChinese ? '提示词' : 'Prompt');
  String get workflowCompletion =>
      localized('workflowCompletion', isChinese ? '补全' : 'Completion');
  String get workflowExactCoverage => localized(
    'workflowExactCoverage',
    isChinese ? '精确覆盖率' : 'Exact coverage',
  );
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

  String get noWorkflowUsage => localized(
    'noWorkflowUsage',
    isChinese ? '暂无工作流用量' : 'No workflow usage yet',
  );
  String get workflowUnavailable => localized(
    'workflowUnavailable',
    isChinese ? '工作流报表暂不可用' : 'Workflow report unavailable',
  );
  String dailyTokenUsage(String date) =>
      isChinese ? '$date 每日 Token 用量' : 'Daily Token Usage · $date';
  String get unknown => localized('unknown', isChinese ? '未知' : 'Unknown');
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
  String get noSupportedTargetsDetected => localized(
    'noSupportedTargetsDetected',
    isChinese ? '未检测到支持的目标。' : 'No supported targets detected.',
  );
  String get scrollToLoadMoreHistories => localized(
    'scrollToLoadMoreHistories',
    isChinese ? '滚动继续加载历史' : 'Scroll to load more histories',
  );
  String get loadingMoreHistories => localized(
    'loadingMoreHistories',
    isChinese ? '正在加载更多历史...' : 'Loading more histories...',
  );
  String get searchHistories =>
      localized('searchHistories', isChinese ? '搜索历史' : 'Search histories');
  String get searchConversations => localized(
    'searchConversations',
    isChinese ? '搜索对话' : 'Search conversations',
  );
  String get searchConversationsHint => localized(
    'searchConversationsHint',
    isChinese
        ? '搜索功能和所有对话的标题、内容'
        : 'Search features, conversation titles, and content',
  );
  String get searchFeaturesGroup =>
      localized('searchFeaturesGroup', isChinese ? '功能' : 'Features');
  String get noConversationSearchResults => localized(
    'noConversationSearchResults',
    isChinese ? '没有匹配的对话' : 'No matching conversations',
  );
  String get collapseHistory =>
      localized('collapseHistory', isChinese ? '收起历史' : 'Collapse history');
  String get expandHistory =>
      localized('expandHistory', isChinese ? '展开历史' : 'Expand history');
  // File chooser labels. File formats are intentionally not translated.
  String get plainTextFile =>
      localized('plainTextFile', isChinese ? '文本' : 'Text');
  String get directory =>
      localized('directory', isChinese ? '目录' : 'Directory');

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
  String get skillHubSubtitle => localized(
    'skillHubSubtitle',
    isChinese
        ? '查看本机智能体已有技能，或将选中技能移入系统废纸篓。'
        : 'Inspect skills already present for local agents or move one to system Trash.',
  );
  String get refreshSkills =>
      localized('refreshSkills', isChinese ? '刷新技能' : 'Refresh Skills');
  String get showSkillHubSettings => localized(
    'showSkillHubSettings',
    isChinese ? '显示技能设置' : 'Show Skill Settings',
  );
  String get hideSkillHubSettings => localized(
    'hideSkillHubSettings',
    isChinese ? '隐藏技能设置' : 'Hide Skill Settings',
  );
  String get allSkills =>
      localized('allSkills', isChinese ? '全部技能' : 'All Skills');
  String get publicSkills =>
      localized('publicSkills', isChinese ? '公共技能' : 'Public Skills');
  String get privateSkills =>
      localized('privateSkills', isChinese ? '私有技能' : 'Private Skills');
  String get skillHubSearchHint =>
      localized('skillHubSearchHint', isChinese ? '搜索技能' : 'Search skills');
  String get publicLabel =>
      localized('publicLabel', isChinese ? '公共' : 'Public');
  String get privateLabel =>
      localized('privateLabel', isChinese ? '私有' : 'Private');
  String get noSkillsFound =>
      localized('noSkillsFound', isChinese ? '未发现技能' : 'No Skills Found');
  String get refreshSkillsHint => localized(
    'refreshSkillsHint',
    isChinese
        ? '刷新后会重新扫描本机技能目录。'
        : 'Refresh to scan local skill directories again.',
  );
  String get noDescription =>
      localized('noDescription', isChinese ? '暂无描述' : 'No description');
  String get skillId => localized('skillId', isChinese ? '技能 ID' : 'Skill ID');
  String get author => localized('author', isChinese ? '作者' : 'Author');
  String get customizeSkillIcon => localized(
    'customizeSkillIcon',
    isChinese ? '自定义技能图标' : 'Customize Skill Icon',
  );
  String get skillIconColor =>
      localized('skillIconColor', isChinese ? '图标颜色' : 'Icon Color');
  String get skillIconGlyph =>
      localized('skillIconGlyph', isChinese ? '图标样式' : 'Icon Glyph');
  String get version => localized('version', isChinese ? '版本' : 'Version');
  String get path => localized('path', isChinese ? '路径' : 'Path');
  String get type => localized('type', isChinese ? '类型' : 'Type');
  String get description =>
      localized('description', isChinese ? '描述' : 'Description');
  String get request => localized('request', isChinese ? '请求' : 'Request');
  String get approve => localized('approve', isChinese ? '批准' : 'Approve');
  String get revoke => localized('revoke', isChinese ? '撤销' : 'Revoke');
  String get installFromGitHub => localized(
    'installFromGitHub',
    isChinese ? '从 GitHub 安装' : 'Install from GitHub',
  );
  String get overwrite =>
      localized('overwrite', isChinese ? '覆盖' : 'Overwrite');
  String get pin => localized('pin', isChinese ? '固定' : 'Pin');
  String get preview => localized('preview', isChinese ? '预览' : 'Preview');
  String get install => localized('install', isChinese ? '安装' : 'Install');
  String get installPlan =>
      localized('installPlan', isChinese ? '安装计划' : 'Install Plan');
  String get installResult =>
      localized('installResult', isChinese ? '安装结果' : 'Install Result');
  String get rollbackSnapshot =>
      localized('rollbackSnapshot', isChinese ? '回滚快照' : 'Rollback Snapshot');
  String get rollback => localized('rollback', isChinese ? '回滚' : 'Rollback');

  String get refreshAgents =>
      localized('refreshAgents', isChinese ? '刷新智能体' : 'Refresh Agents');
  String get scanQrCode =>
      localized('scanQrCode', isChinese ? '扫描二维码' : 'Scan QR Code');
  String get addDevice =>
      localized('addDevice', isChinese ? '添加设备' : 'Add Device');
  String get pairDevice =>
      localized('pairDevice', isChinese ? '配对设备' : 'Pair Device');
  String get pinToTop => localized('pinToTop', isChinese ? '置顶' : 'Pin To Top');
  String get unpinFromTop =>
      localized('unpinFromTop', isChinese ? '取消置顶' : 'Unpin From Top');
  String get pinned => localized('pinned', isChinese ? '已置顶' : 'Pinned');
  String get pairingInviteToken =>
      localized('pairingInviteToken', isChinese ? '邀请令牌' : 'Invite Token');
  String get pairingQrDetected => localized(
    'pairingQrDetected',
    isChinese ? '已识别二维码，正在配对...' : 'QR detected, pairing...',
  );
  String get pairingScanSuccess => localized(
    'pairingScanSuccess',
    isChinese ? '扫描成功，设备已配对。' : 'Scan successful. Device paired.',
  );
  String get pairingScanFailed => localized(
    'pairingScanFailed',
    isChinese
        ? '配对失败，请重新扫描或粘贴邀请。'
        : 'Pairing failed. Scan again or paste the invite.',
  );
  String get unpairedDevice =>
      localized('unpairedDevice', isChinese ? '未配对设备' : 'Unpaired Device');
  String get mac => localized('mac', 'Mac');

  String get addTarget =>
      localized('addTarget', isChinese ? '添加目标' : 'Add target');
  String get adding => localized('adding', isChinese ? '添加中...' : 'Adding...');
  String get rescan => localized('rescan', isChinese ? '重新扫描' : 'Rescan');
  String get scanning =>
      localized('scanning', isChinese ? '扫描中...' : 'Scanning...');
  String get scanningLocalAgents => localized(
    'scanningLocalAgents',
    isChinese ? '正在扫描可用智能体...' : 'Scanning available agents...',
  );
  String get noLocalAgentsFound => localized(
    'noLocalAgentsFound',
    isChinese ? '未发现可用智能体' : 'No available agents found',
  );
  String get agentTabNeedsApproval =>
      localized('agentTabNeedsApproval', isChinese ? '等待批准' : 'Needs approval');
  String get agentTabWorkFinished =>
      localized('agentTabWorkFinished', isChinese ? '工作已完成' : 'Work finished');
  String get selectAgentToView => localized(
    'selectAgentToView',
    isChinese ? '选择一个智能体查看历史并对话' : 'Select an agent to view histories and chat',
  );
  String get welcome => localized('welcome', isChinese ? '欢迎' : 'Welcome');
  String get mobileAppPairing => localized(
    'mobileAppPairing',
    isChinese ? '移动 App 配对' : 'Pair Mobile App',
  );
  String get welcomeNewGroupConversation => localized(
    'welcomeNewGroupConversation',
    isChinese ? '新群聊' : 'New Group Chat',
  );

  String get target => localized('target', isChinese ? '目标' : 'Target');
  String get configPath =>
      localized('configPath', isChinese ? '配置路径' : 'Config path');
  String get binaryPath =>
      localized('binaryPath', isChinese ? '程序路径' : 'Binary path');
  String get historyRoot =>
      localized('historyRoot', isChinese ? '历史目录' : 'History root');
  String get targetLocation =>
      localized('targetLocation', isChinese ? '运行位置' : 'Runtime location');
  String get localMachine =>
      localized('localMachine', isChinese ? '本机' : 'Local machine');
  String get virtualMachine => localized(
    'virtualMachine',
    isChinese ? '虚拟机（SSH）' : 'Virtual machine (SSH)',
  );
  String get virtualMachineHost => localized(
    'virtualMachineHost',
    isChinese ? '虚拟机主机名或 IP' : 'VM host or IP',
  );
  String get sshPort =>
      localized('sshPort', isChinese ? 'SSH 端口（可选）' : 'SSH port (optional)');
  String get sshUser =>
      localized('sshUser', isChinese ? 'SSH 用户（可选）' : 'SSH user (optional)');
  String get remoteExecutable => localized(
    'remoteExecutable',
    isChinese ? '虚拟机内程序路径' : 'Executable in VM',
  );
  String get remoteWorkingDirectory => localized(
    'remoteWorkingDirectory',
    isChinese ? '虚拟机内工作目录' : 'Working directory in VM',
  );
  String virtualMachineDestination(String destination) => isChinese
      ? '虚拟机对话目标：$destination'
      : 'Virtual machine conversation destination: $destination';
  String get fieldRequired =>
      localized('fieldRequired', isChinese ? '此项必填' : 'This field is required');
  String get invalidSshValue => localized(
    'invalidSshValue',
    isChinese ? '请输入有效的 SSH 参数' : 'Enter a valid SSH value',
  );
  String get absoluteGuestPathRequired => localized(
    'absoluteGuestPathRequired',
    isChinese
        ? '请输入以 / 开头的虚拟机绝对路径'
        : 'Enter an absolute VM path beginning with /',
  );
  String get cancel => localized('cancel', isChinese ? '取消' : 'Cancel');
  String get apply => localized('apply', isChinese ? '应用' : 'Apply');
  String get inspect => localized('inspect', isChinese ? '查看' : 'Inspect');
  String get plan => localized('plan', isChinese ? '计划' : 'Plan');

  String get configured =>
      localized('configured', isChinese ? '已配置' : 'Configured');
  String get detected => localized('detected', isChinese ? '已检测到' : 'Detected');
  String get manual => localized('manual', isChinese ? '手动添加' : 'Manual');
  String get unavailable =>
      localized('unavailable', isChinese ? '不可用' : 'Unavailable');
  String get notConfigured =>
      localized('notConfigured', isChinese ? '未配置' : 'Not configured');

  String get historyConversations => localized(
    'historyConversations',
    isChinese ? '历史对话' : 'Conversation history',
  );
  String get agentsSidebarConversations => localized(
    'agentsSidebarConversations',
    isChinese ? '对话' : 'CONVERSATIONS',
  );
  String get ungroupedConversationProject => localized(
    'ungroupedConversationProject',
    isChinese ? '未关联项目' : 'No project',
  );
  String get historyConversationSearchHint => localized(
    'historyConversationSearchHint',
    isChinese ? '搜索历史对话' : 'Search conversations',
  );
  String get noMatchingNativeHistories => localized(
    'noMatchingNativeHistories',
    isChinese ? '没有匹配的历史对话' : 'No matching histories',
  );
  String conversationCount(int count) =>
      isChinese ? '$count 条对话' : '$count conversations';
  String get conversations =>
      localized('conversations', isChinese ? '对话' : 'Conversations');
  String get conversationListNav =>
      localized('conversationListNav', isChinese ? '对话' : 'Chats');
  String get skillsNav => localized('skillsNav', isChinese ? '技能' : 'Skills');
  String get pluginsNav =>
      localized('pluginsNav', isChinese ? '插件' : 'Plugins');
  String get adaptationDeep =>
      localized('adaptationDeep', isChinese ? '深度适配' : 'Deep');
  String get adaptationPartial =>
      localized('adaptationPartial', isChinese ? '部分适配' : 'Partial');
  String get adaptationPending =>
      localized('adaptationPending', isChinese ? '待评估' : 'Pending');
  String get agentHubInstalled =>
      localized('agentHubInstalled', isChinese ? '已安装' : 'Installed');
  String get agentHubNotInstalled =>
      localized('agentHubNotInstalled', isChinese ? '未安装' : 'Not installed');
  String get agentHubExternal =>
      localized('agentHubExternal', isChinese ? '外部安装' : 'External');
  String get agentHubFailed =>
      localized('agentHubFailed', isChinese ? '失败' : 'Failed');
  String get agentHubCatalogFailed => localized(
    'agentHubCatalogFailed',
    isChinese ? '无法加载智能体目录' : 'Unable to load agent catalog',
  );
  String get agentHubVisit =>
      localized('agentHubVisit', isChinese ? '访问' : 'Visit →');
  String get agentHubVisitFailed => localized(
    'agentHubVisitFailed',
    isChinese ? '无法打开主页' : 'Unable to open homepage',
  );
  String get agentHubUpdate =>
      localized('agentHubUpdate', isChinese ? '更新' : 'Update');
  String get agentHubOpen =>
      localized('agentHubOpen', isChinese ? '对话' : 'Chat');
  String get agentHubBack =>
      localized('agentHubBack', isChinese ? '返回' : 'Back');
  String get agentHubUninstall =>
      localized('agentHubUninstall', isChinese ? '卸载' : 'Uninstall');
  String get mobileNav => localized('mobileNav', isChinese ? '移动' : 'Mobile');
  String get statsNav => localized('statsNav', isChinese ? '统计' : 'Stats');
  String get statsPanel =>
      localized('statsPanel', isChinese ? '统计面板' : 'Statistics');
  String get newConversation =>
      localized('newConversation', isChinese ? '新对话' : 'New Chat');
  String get untitledConversation => localized(
    'untitledConversation',
    isChinese ? '未命名对话' : 'Untitled conversation',
  );
  String get createConversation =>
      localized('createConversation', isChinese ? '新建' : 'New');
  String get newGroupConversation =>
      localized('newGroupConversation', isChinese ? '新群组' : 'New Group');
  String get recycleBin =>
      localized('recycleBin', isChinese ? '回收站' : 'Recycle Bin');
  String get archivedConversations =>
      localized('archivedConversations', isChinese ? '归档' : 'Archived');
  String get archivedConversationsTitle => localized(
    'archivedConversationsTitle',
    isChinese ? '已归档对话' : 'Archived conversations',
  );
  String get searchArchivedConversations => localized(
    'searchArchivedConversations',
    isChinese ? '搜索已归档对话' : 'Search archived conversations',
  );
  String get archivedConversationsHint => localized(
    'archivedConversationsHint',
    isChinese
        ? '恢复后，对话会重新出现在主列表。'
        : 'Restored conversations return to the main list.',
  );
  String get noArchivedConversations => localized(
    'noArchivedConversations',
    isChinese ? '没有已归档对话' : 'No archived conversations',
  );
  String get noMatchingArchivedConversations => localized(
    'noMatchingArchivedConversations',
    isChinese ? '没有匹配的已归档对话' : 'No matching archived conversations',
  );
  String conversationRestored(String title) =>
      isChinese ? '已恢复“$title”。' : 'Restored “$title”.';
  String archivedConversationFailure(String stage, String code) => isChinese
      ? '归档对话操作失败（$stage：$code）'
      : 'Archived conversation operation failed ($stage: $code)';
  String get retry => localized('retry', isChinese ? '重试' : 'Retry');
  String get recentConversations => localized(
    'recentConversations',
    isChinese ? '最近对话' : 'Recent conversations',
  );
  String get noConversationsYet => localized(
    'noConversationsYet',
    isChinese ? '还没有对话' : 'No conversations yet',
  );
  String get noTrashedConversations => localized(
    'noTrashedConversations',
    isChinese ? '回收站为空' : 'Recycle bin is empty',
  );
  String get delete => localized('delete', isChinese ? '删除' : 'Delete');
  String get deleteSkillTitle => localized(
    'deleteSkillTitle',
    isChinese ? '删除这个技能？' : 'Delete this skill?',
  );
  String trashSkillMessage(String title) => isChinese
      ? '“$title” 将移入系统回收站，可在回收站中恢复。'
      : '"$title" will move to the system trash, where it can be restored.';
  String get moveToSystemTrash =>
      localized('moveToSystemTrash', isChinese ? '移入回收站' : 'Move to Trash');
  String skillMovedToSystemTrash(String title) =>
      isChinese ? '已将“$title”移入系统回收站。' : 'Moved "$title" to the system trash.';
  String get skillTrashFailed => localized(
    'skillTrashFailed',
    isChinese
        ? '无法将技能移入系统回收站，请确认技能仍存在且路径可访问。'
        : 'Could not move the skill to the system trash. Check that it still exists and is accessible.',
  );
  String get restore => localized('restore', isChinese ? '恢复' : 'Restore');
  String get confirmDeleteConversationTitle => localized(
    'confirmDeleteConversationTitle',
    isChinese ? '删除这段对话？' : 'Delete this conversation?',
  );
  String confirmDeleteConversationMessage(String title) => isChinese
      ? '“$title” 会移入本机回收站，并在 30 天后清理。'
      : '"$title" will move to the local recycle bin and be cleared after 30 days.';
  String get deletedConversationsExpire => localized(
    'deletedConversationsExpire',
    isChinese
        ? '删除的对话会在本机回收站保留 30 天。'
        : 'Deleted conversations stay in the local recycle bin for 30 days.',
  );
  String get loading =>
      localized('loading', isChinese ? '加载中...' : 'Loading...');
  String get loadingNativeHistories => localized(
    'loadingNativeHistories',
    isChinese ? '正在加载原生智能体历史...' : 'Loading native agent histories...',
  );
  String get noNativeHistories => localized(
    'noNativeHistories',
    isChinese ? '暂无原生智能体历史' : 'No native agent histories yet',
  );
  String get deleteNativeHistory => localized(
    'deleteNativeHistory',
    isChinese ? '删除原生智能体历史' : 'Delete native agent history',
  );
  String get archiveAgentConversations => localized(
    'archiveAgentConversations',
    isChinese ? '归档当前智能体对话' : 'Archive agent conversations',
  );
  String get collapseHistoryConversations => localized(
    'collapseHistoryConversations',
    isChinese ? '收起历史对话' : 'Collapse conversation history',
  );
  String get expandHistoryConversations => localized(
    'expandHistoryConversations',
    isChinese ? '展开历史对话' : 'Expand conversation history',
  );
  String get collapseAgentsSidebar => localized(
    'collapseAgentsSidebar',
    isChinese ? '收起侧边栏' : 'Collapse sidebar',
  );
  String get expandAgentsSidebar =>
      localized('expandAgentsSidebar', isChinese ? '展开侧边栏' : 'Expand sidebar');
  String messagesCount(int count) =>
      isChinese ? '$count 条消息' : '$count messages';
  String get noMessagesInHistory =>
      localized('noMessagesInHistory', isChinese ? '还没有消息' : 'No messages yet');
  String get scrollToLatestMessages => localized(
    'scrollToLatestMessages',
    isChinese ? '跳到最新消息' : 'Jump to latest',
  );

  String get keywords => localized('keywords', isChinese ? '关键词' : 'Keywords');
  String get archiveDirectory =>
      localized('archiveDirectory', isChinese ? '归档目录' : 'Archive directory');
  String get archive => localized('archive', isChinese ? '归档' : 'Archive');
  String get backupConversations => localized(
    'backupConversations',
    isChinese ? '备份对话' : 'Back up conversations',
  );
  String get allConversations =>
      localized('allConversations', isChinese ? '全部对话' : 'All conversations');
  String get exactKeyword =>
      localized('exactKeyword', isChinese ? '精确关键词' : 'Exact keyword');
  String get archiveDestinationRequired => localized(
    'archiveDestinationRequired',
    isChinese
        ? '请先在设置中选择本机归档目录。'
        : 'Choose a local archive directory in Settings first.',
  );
  String archiveDestination(String path) =>
      isChinese ? '本机归档目录：$path' : 'Local archive directory: $path';
  String get previewAndBackup =>
      localized('previewAndBackup', isChinese ? '预览并备份' : 'Preview & Back Up');
  String get openDirectory =>
      localized('openDirectory', isChinese ? '跳转' : 'Open');
  String recordsCount(String count) =>
      isChinese ? '$count 条记录' : '$count records';

  String get you => localized('you', isChinese ? '你' : 'You');
  String get agent => localized('agent', isChinese ? '智能体' : 'Agent');
  String get subagentTask =>
      localized('subagentTask', isChinese ? '子智能体任务' : 'Subagent task');
  String subagentSteps(int count) =>
      isChinese ? '$count 步' : '$count ${count == 1 ? 'step' : 'steps'}';
  String subagentToolCalls(int count) => isChinese
      ? '$count 次工具调用'
      : '$count tool ${count == 1 ? 'call' : 'calls'}';
  String subagentNestedTasks(int count) => isChinese
      ? '$count 个子任务'
      : '$count nested ${count == 1 ? 'task' : 'tasks'}';
  String get agentProcess =>
      localized('agentProcess', isChinese ? '智能体过程' : 'Agent process');
  String get runtimeUpdateTitle => localized(
    'runtimeUpdateTitle',
    isChinese
        ? 'Cursor Agent 正在自动更新'
        : 'Cursor Agent is updating automatically',
  );
  String get runtimeUpdateCompleted => localized(
    'runtimeUpdateCompleted',
    isChinese ? '更新完成' : 'Update completed',
  );
  String get runtimeUpdateInterrupted => localized(
    'runtimeUpdateInterrupted',
    isChinese ? '更新中断' : 'Update interrupted',
  );
  String get runtimeUpdateStaleLockHint => localized(
    'runtimeUpdateStaleLockHint',
    isChinese ? '已清理过期安装锁' : 'Stale install lock removed',
  );
  String get workedBriefly =>
      localized('workedBriefly', isChinese ? '少于 1 秒' : 'Under 1s');
  String get reasoningProcess =>
      localized('reasoningProcess', isChinese ? '思考过程' : 'Reasoning');
  String get toolExecution =>
      localized('toolExecution', isChinese ? '工具执行' : 'Tool activity');
  String get agentActivity =>
      localized('agentActivity', isChinese ? '智能体活动' : 'Agent activity');
  String get runtimeLog =>
      localized('runtimeLog', isChinese ? '运行记录' : 'Runtime log');
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
  String get expandProcessDetails => localized(
    'expandProcessDetails',
    isChinese ? '展开过程详情' : 'Expand process details',
  );
  String get collapseProcessDetails => localized(
    'collapseProcessDetails',
    isChinese ? '收起过程详情' : 'Collapse process details',
  );
  String get reasoningSummary =>
      localized('reasoningSummary', isChinese ? '思考摘要' : 'Reasoning summary');
  String get providerSummary =>
      localized('providerSummary', isChinese ? '提供方摘要' : 'Provider summary');

  // Messaging presentation (participant flow, details panel).
  String get agentBadge => localized('agentBadge', 'AGENT');
  String get assistantBadge => localized('assistantBadge', 'ASSISTANT');
  String get subagentBadge => localized('subagentBadge', 'SUBAGENT');
  String get assistantActiveTooltip => localized(
    'assistantActiveTooltip',
    isChinese ? '暂停 Assistant 的后续派发' : 'Pause future Assistant dispatch',
  );
  String get assistantPausedTooltip => localized(
    'assistantPausedTooltip',
    isChinese ? '激活 Assistant' : 'Activate Assistant',
  );
  String get configureAssistantTooltip => localized(
    'configureAssistantTooltip',
    isChinese ? '配置 Assistant' : 'Configure Assistant',
  );
  String get assistantProfileTitle => localized(
    'assistantProfileTitle',
    isChinese ? 'Assistant 配置' : 'Assistant profile',
  );
  String get assistantPausedStatus => localized(
    'assistantPausedStatus',
    isChinese ? '你的助手已暂停' : 'Your Assistant is paused',
  );
  String get assistantNeedsConfigurationStatus => localized(
    'assistantNeedsConfigurationStatus',
    isChinese ? '配置你的助手' : 'Configure your Assistant',
  );
  String get assistantWorkingAloneStatus => localized(
    'assistantWorkingAloneStatus',
    isChinese ? '你的助手正在独自工作' : 'Your Assistant is working independently',
  );
  String assistantCoordinatingStatus(int count) => isChinese
      ? '你的助手正在协调 $count 个 Subagents'
      : 'Your Assistant is coordinating $count ${count == 1 ? 'Subagent' : 'Subagents'}';
  String get assistantActionsTooltip => localized(
    'assistantActionsTooltip',
    isChinese ? '助手操作' : 'Assistant actions',
  );
  String get archiveGroupConversationTitle => localized(
    'archiveGroupConversationTitle',
    isChinese ? '归档这段群聊对话？' : 'Archive this group conversation?',
  );
  String archiveGroupConversationMessage(String title) => isChinese
      ? '“$title” 与其真正涉及的对话会一起归档保存，随后开启新的助手对话。'
      : '“$title” and the conversations it involves will be archived together, then a new Assistant conversation opens.';
  String archiveDefaultGroupConversationMessage(String title) => isChinese
      ? '“$title” 将清空历史并重置为全新对话，其真正涉及的对话会一起归档保存。'
      : '“$title” clears its history and resets to a fresh conversation; the conversations it involves are archived together.';
  String get conversationResetNotice => localized(
    'conversationResetNotice',
    isChinese ? '已开启新对话' : 'New conversation started',
  );
  String get archivedContinuityChildren => localized(
    'archivedContinuityChildren',
    isChinese ? '已归档子会话' : 'Archived children',
  );
  String get discardPendingImages => localized(
    'discardPendingImages',
    isChinese ? '丢弃待发送的图片' : 'Discard pending images',
  );
  String get contacts =>
      localized('contacts', isChinese ? '对话' : 'Conversations');
  String get conversationBack =>
      localized('conversationBack', isChinese ? '返回上一级' : 'Back one level');
  String mentionAgent(String agent) =>
      isChinese ? '@ $agent' : 'Mention $agent';
  String openAgentConversations(String agent) =>
      isChinese ? '打开 $agent 的对话' : 'Open $agent conversations';
  String get automaticAdaptation => localized(
    'automaticAdaptation',
    isChinese ? '自动适配' : 'Automatic adaptation',
  );
  String get adaptiveFlywheel =>
      localized('adaptiveFlywheel', 'Adaptive Flywheel');
  String get noAuthorizedStrategies => localized(
    'noAuthorizedStrategies',
    isChinese ? '没有已授权的策略' : 'No authorized strategies',
  );
  String get exitStrategyMode => localized(
    'exitStrategyMode',
    isChinese ? '退出策略模式' : 'Exit strategy mode',
  );
  String get groupConversation =>
      localized('groupConversation', isChinese ? '群聊' : 'Group');
  String get groupConversationName =>
      localized('groupConversationName', isChinese ? '群聊名称' : 'Group name');
  String get createGroupConversation =>
      localized('createGroupConversation', isChinese ? '创建' : 'Create');
  String get selectGroupConversationAgents => localized(
    'selectGroupConversationAgents',
    isChinese ? '选择至少一个 Agent' : 'Select at least one Agent',
  );
  String get groupConversationNeedsAgent => localized(
    'groupConversationNeedsAgent',
    isChinese
        ? '至少需要一个可用 Agent 才能创建群聊。'
        : 'At least one available Agent is required.',
  );
  String get noGroupConversationsYet => localized(
    'noGroupConversationsYet',
    isChinese ? '还没有群聊' : 'No groups yet',
  );
  String groupConversationMemberCount(int count) =>
      isChinese ? '$count 位成员' : '$count members';
  String get groupConversationMembershipChangeTitle => localized(
    'groupConversationMembershipChangeTitle',
    isChinese ? '群成员变更' : 'Group membership change',
  );
  String get groupConversationAvailabilityChangeTitle => localized(
    'groupConversationAvailabilityChangeTitle',
    isChinese ? '成员状态变更' : 'Member status change',
  );
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
  String get groupConversationEventDetailsUnavailable => localized(
    'groupConversationEventDetailsUnavailable',
    isChinese
        ? '旧记录未保存具体变更'
        : 'This older record does not include change details',
  );
  String get groupConversationUnknownMember => localized(
    'groupConversationUnknownMember',
    isChinese ? '未知成员' : 'Unknown member',
  );
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
  String groupConversationFailureSummary(String code, String failureRef) =>
      switch (code.trim()) {
        'codex_usage_limit_exceeded' =>
          isChinese
              ? 'Codex 模型额度已用完 · $failureRef'
              : 'Codex model usage limit reached · $failureRef',
        'continuity_assistant_turn_invalid' =>
          isChinese
              ? '助手没有留下可用回复 · $failureRef'
              : 'Assistant left no usable reply · $failureRef',
        _ => groupConversationFailureCapsule(failureRef),
      };
  String groupConversationFailureRecovery(String recovery) => switch (recovery
      .trim()) {
    'select_available_model_or_wait_for_quota_reset' =>
      isChinese
          ? '请选择其它可用模型，或等待额度重置后重试。'
          : 'Choose another available model, or retry after the usage limit resets.',
    _ => '',
  };
  String quotaUsageCardTitle(String provider) =>
      isChinese ? '$provider 配额用量' : '$provider quota usage';
  String quotaWindowUsedPercent(int percent) =>
      isChinese ? '已用 $percent%' : '$percent% Used';

  /// Absolute budget line for currency-metered quota windows.
  String quotaWindowAmount(String used, String limit) =>
      isChinese ? '已用 $used / $limit' : '$used / $limit used';
  String quotaWindowSpent(String used) => isChinese ? '已用 $used' : '$used used';
  String quotaWindowResetCountdown(String duration) =>
      isChinese ? '$duration后重置' : 'Resets in $duration';
  String quotaSnapshotCapturedAgo(String duration) =>
      isChinese ? '数据捕获于$duration前' : 'Captured $duration ago';
  String get quotaDurationUnderMinute =>
      localized('quotaDurationUnderMinute', isChinese ? '不到 1 分钟' : '<1 min');
  String quotaDurationMinutes(int minutes) =>
      isChinese ? '$minutes 分钟' : '${minutes}m';
  String quotaDurationHoursMinutes(int hours, int minutes) =>
      isChinese ? '$hours 小时 $minutes 分钟' : '${hours}h ${minutes}m';
  String quotaDurationDaysHours(int days, int hours) =>
      isChinese ? '$days 天 $hours 小时' : '${days}d ${hours}h';
  String groupConversationFailureDetail(String stage, String code) =>
      '$stage · $code';
  String get copyFailureReport =>
      localized('copyFailureReport', isChinese ? '复制报错' : 'Copy error');
  String get attachments =>
      localized('attachments', isChinese ? '附件' : 'Attachments');
  String get imageAttachment =>
      localized('imageAttachment', isChinese ? '图片' : 'Image');
  String get imageUnavailable =>
      localized('imageUnavailable', isChinese ? '图片不可用' : 'Image unavailable');
  String get localUser =>
      localized('localUser', isChinese ? '本地用户' : 'Local User');
  String get appearanceAndLayout => localized(
    'appearanceAndLayout',
    isChinese ? '外观与布局' : 'Appearance & Layout',
  );
  String get notifications =>
      localized('notifications', isChinese ? '通知' : 'Notifications');
  String get noNotifications =>
      localized('noNotifications', isChinese ? '暂无通知' : 'No notifications');
  String skillInvocationsCount(int count) => isChinese
      ? '$count 次调用'
      : '$count ${count == 1 ? 'invocation' : 'invocations'}';
  String get allTimeInvocations => localized(
    'allTimeInvocations',
    isChinese ? '累计调用' : 'All-time invocations',
  );
  String get today => localized('today', isChinese ? '今天' : 'Today');
  String get yesterday =>
      localized('yesterday', isChinese ? '昨天' : 'Yesterday');
  String get earlier => localized('earlier', isChinese ? '更早' : 'Earlier');
  String get priority => localized('priority', isChinese ? '优先' : 'Priority');
  String get otherConversations => localized(
    'otherConversations',
    isChinese ? '其它对话' : 'Other conversations',
  );

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

  String get working => localized('working', isChinese ? '正在工作…' : 'Working…');
  String get lifecycleSubmitted =>
      localized('lifecycleSubmitted', isChinese ? '消息已发送' : 'Message sent');
  String get lifecycleAccepted =>
      localized('lifecycleAccepted', isChinese ? '智能体已接收' : 'Agent received');
  String get lifecycleProcessing => localized(
    'lifecycleProcessing',
    isChinese ? '智能体处理中' : 'Agent is working',
  );
  String get lifecycleResponding => localized(
    'lifecycleResponding',
    isChinese ? '正在生成回复' : 'Writing response',
  );
  String get lifecycleCompleted => localized(
    'lifecycleCompleted',
    isChinese ? '回复已完成' : 'Response complete',
  );
  String get lifecycleFailed =>
      localized('lifecycleFailed', isChinese ? '处理失败' : 'Processing failed');
  String get lifecycleSubmittedShort =>
      localized('lifecycleSubmittedShort', isChinese ? '已发送' : 'Sent');
  String get lifecycleAcceptedShort =>
      localized('lifecycleAcceptedShort', isChinese ? '已接收' : 'Received');
  String get lifecycleProcessingShort =>
      localized('lifecycleProcessingShort', isChinese ? '处理' : 'Working');
  String get lifecycleRespondingShort =>
      localized('lifecycleRespondingShort', isChinese ? '回复中' : 'Replying');
  String get lifecycleCompletedShort =>
      localized('lifecycleCompletedShort', isChinese ? '完成' : 'Done');
  String get messagingEmptyConversationGuide => localized(
    'messagingEmptyConversationGuide',
    isChinese ? '选择一个对话，或开始一个新对话' : 'Select a conversation or start a new one',
  );
  String get runtimeSection =>
      localized('runtimeSection', isChinese ? '运行时' : 'Runtime');
  String get capabilitiesSection =>
      localized('capabilitiesSection', isChinese ? '能力' : 'Capabilities');
  String get connectionSection =>
      localized('connectionSection', isChinese ? '连接' : 'Connection');
  String get sessionSection =>
      localized('sessionSection', isChinese ? '会话' : 'Session');
  String get messages => localized('messages', isChinese ? '消息' : 'Messages');
  String get createdTime =>
      localized('createdTime', isChinese ? '创建时间' : 'Created');
  String get showDetails =>
      localized('showDetails', isChinese ? '显示详情' : 'Show details');
  String get hideDetails =>
      localized('hideDetails', isChinese ? '隐藏详情' : 'Hide details');

  String get toolCall =>
      localized('toolCall', isChinese ? '工具调用' : 'Tool call');
  String get nativeAgentActivity => localized(
    'nativeAgentActivity',
    isChinese ? '原生智能体活动' : 'Native agent activity',
  );
  String get toolResult =>
      localized('toolResult', isChinese ? '工具结果' : 'Tool result');
  String get nativeAgentResult => localized(
    'nativeAgentResult',
    isChinese ? '原生智能体结果' : 'Native agent result',
  );
  String get reasoning =>
      localized('reasoning', isChinese ? '思考' : 'Reasoning');
  String get sensitiveDetailsHidden => localized(
    'sensitiveDetailsHidden',
    isChinese ? '敏感详情已隐藏' : 'Sensitive details hidden',
  );
  String get metadata => localized('metadata', isChinese ? '元数据' : 'Metadata');
  String get processError =>
      localized('processError', isChinese ? '错误' : 'Error');
  String get nativeAgentError => localized(
    'nativeAgentError',
    isChinese ? '原生智能体错误' : 'Native agent error',
  );
  String get nativeEvent =>
      localized('nativeEvent', isChinese ? '原生事件' : 'Native event');
  String get nativeAgentEvent => localized(
    'nativeAgentEvent',
    isChinese ? '原生智能体事件' : 'Native agent event',
  );
  String get additionalOperationsHidden => localized(
    'additionalOperationsHidden',
    isChinese
        ? '为保持对话流畅，其余操作已隐藏。'
        : 'Additional operations are hidden to keep this conversation responsive.',
  );
  String get conversationHistoryTruncated => localized(
    'conversationHistoryTruncated',
    isChinese
        ? '较早的历史消息未载入；当前显示最近的对话。'
        : 'Earlier history was not loaded; the most recent conversation is shown.',
  );
  String get conversationDetailsTruncated => localized(
    'conversationDetailsTruncated',
    isChinese
        ? '部分嵌套过程详情未载入；最终对话消息仍保留。'
        : 'Some nested process details were not loaded; final conversation messages remain available.',
  );
  String get conversationHistoryAndDetailsTruncated => localized(
    'conversationHistoryAndDetailsTruncated',
    isChinese
        ? '较早消息和部分嵌套过程详情未载入；当前显示最近的完整对话骨架。'
        : 'Earlier messages and some nested process details were not loaded; the recent conversation outline remains available.',
  );
  String get invocationDetailsHidden => localized(
    'invocationDetailsHidden',
    isChinese ? '调用详情已隐藏。' : 'Invocation details are hidden.',
  );
  String get toolResultRecorded => localized(
    'toolResultRecorded',
    isChinese ? '已记录原生工具结果。' : 'The native tool result was recorded.',
  );
  String get reasoningDetailsRedacted => localized(
    'reasoningDetailsRedacted',
    isChinese ? '思考详情已脱敏。' : 'Reasoning details are redacted.',
  );
  String get nativeMetadataHidden => localized(
    'nativeMetadataHidden',
    isChinese ? '原生敏感元数据已隐藏。' : 'Sensitive native metadata is hidden.',
  );
  String get nativeAgentErrorReported => localized(
    'nativeAgentErrorReported',
    isChinese ? '原生智能体报告了错误。' : 'The native agent reported an error.',
  );
  String get nativeEventDetailsHidden => localized(
    'nativeEventDetailsHidden',
    isChinese ? '原生事件详情已隐藏。' : 'Native event details are hidden.',
  );
  String get fastModeLabel => localized('fastModeLabel', 'Fast');
  String get currentConversation => localized(
    'currentConversation',
    isChinese ? '当前对话' : 'Current Conversation',
  );
  String get addDailyConversationAgent =>
      localized('addDailyConversationAgent', isChinese ? '添加智能体' : 'Add agent');
  String get confirmDailyConversationSelection => localized(
    'confirmDailyConversationSelection',
    isChinese ? '确认添加' : 'Confirm',
  );
  String get noModelsFound =>
      localized('noModelsFound', isChinese ? '未发现模型' : 'No Models Found');
  String get modelSearchHint =>
      localized('modelSearchHint', isChinese ? '搜索模型' : 'Search models');
  String get discoveringModels => localized(
    'discoveringModels',
    isChinese ? '正在发现模型…' : 'Discovering models…',
  );
  String get noAgentsFound =>
      localized('noAgentsFound', isChinese ? '未发现智能体' : 'No Agents Found');
  String get noReasoningEffortsFound => localized(
    'noReasoningEffortsFound',
    isChinese ? '未发现思考强度' : 'No Reasoning Efforts Found',
  );
  String get agentModeLabel =>
      localized('agentModeLabel', isChinese ? 'Agent' : 'Agent');
  String get planModeLabel =>
      localized('planModeLabel', isChinese ? 'Plan' : 'Plan');
  String get conversationParitySendDisabled => localized(
    'conversationParitySendDisabled',
    isChinese ? '发送已关闭' : 'Sending disabled',
  );
  String get conversationParityCapabilities => localized(
    'conversationParityCapabilities',
    isChinese ? '能力矩阵' : 'Capability matrix',
  );
  String get conversationParityCapabilitiesUnavailable => localized(
    'conversationParityCapabilitiesUnavailable',
    isChinese ? '暂无能力矩阵' : 'Capability matrix unavailable',
  );
  String get conversationParityEvidenceAge => localized(
    'conversationParityEvidenceAge',
    isChinese ? '证据状态' : 'Evidence age',
  );
  String get conversationParityEvidenceNote => localized(
    'conversationParityEvidenceNote',
    isChinese ? '验收记录' : 'Acceptance note',
  );
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
  String get send => localized('send', isChinese ? '发送' : 'Send');
  String conversationSendFailed(String reason) =>
      isChinese ? '发送失败：$reason' : 'Send failed: $reason';
  String get conversationAuthorizeRuntimeAction => localized(
    'conversationAuthorizeRuntimeAction',
    isChinese ? '授权' : 'Authorize',
  );
  String get conversationAuthorizingRuntimeAction => localized(
    'conversationAuthorizingRuntimeAction',
    isChinese ? '授权中…' : 'Authorizing…',
  );
  String conversationPermissionDenied(String tool) => isChinese
      ? '$tool 的权限请求被拒绝，回复中未执行该操作。'
      : '$tool was denied permission; the action was not performed.';
  String get conversationPermissionAllowAction => localized(
    'conversationPermissionAllowAction',
    isChinese ? '允许' : 'Allow',
  );
  String get conversationPermissionAllowAndRememberAction => localized(
    'conversationPermissionAllowAndRememberAction',
    isChinese ? '允许并加入白名单' : 'Allow and remember',
  );
  String get conversationPermissionDenyAction =>
      localized('conversationPermissionDenyAction', isChinese ? '拒绝' : 'Deny');

  String get llmGatewayStart =>
      localized('llmGatewayStart', isChinese ? '启动' : 'Start');
  String get llmGatewayStarting =>
      localized('llmGatewayStarting', isChinese ? '启动中…' : 'Starting…');
  String get llmGatewayStop =>
      localized('llmGatewayStop', isChinese ? '停止' : 'Stop');
  String get llmGatewayStarted => localized(
    'llmGatewayStarted',
    isChinese ? 'Gateway 已启动。' : 'Gateway started.',
  );
  String get llmGatewayStartFailed => localized(
    'llmGatewayStartFailed',
    isChinese ? 'Gateway 启动失败。' : 'Gateway failed to start.',
  );
  String get llmGatewayStopped => localized(
    'llmGatewayStopped',
    isChinese ? 'Gateway 已停止。' : 'Gateway stopped.',
  );
  String get llmGatewayStopFailed => localized(
    'llmGatewayStopFailed',
    isChinese ? 'Gateway 停止失败。' : 'Gateway failed to stop.',
  );
  String get llmGatewayNotReadyWaitingForAuthorization => localized(
    'llmGatewayNotReadyWaitingForAuthorization',
    isChinese
        ? '尚未就绪，点击授权并启动以加载 API Key'
        : 'Not ready; authorize and start to load API keys',
  );
  String get llmGatewayKeysLoadedStartToApply => localized(
    'llmGatewayKeysLoadedStartToApply',
    isChinese
        ? 'API Key 已加载，点击启动应用到 Gateway'
        : 'API keys loaded; start to apply them',
  );
  String get llmGatewayKeysLoadedWaitingForService => localized(
    'llmGatewayKeysLoadedWaitingForService',
    isChinese ? 'API Key 已加载，等待服务启动' : 'API keys loaded; waiting for service',
  );

  String get appearanceDayNight =>
      localized('appearanceDayNight', isChinese ? '明暗模式' : 'Brightness');
  String get appearanceDay =>
      localized('appearanceDay', isChinese ? '明亮' : 'Light');
  String get appearanceNight =>
      localized('appearanceNight', isChinese ? '暗黑' : 'Dark');
  String get appearancePreset =>
      localized('appearancePreset', isChinese ? '主题风格' : 'Theme style');
  String get layoutProfile =>
      localized('layoutProfile', isChinese ? '界面布局' : 'Interface Layout');
  String get layoutProfileDescription => localized(
    'layoutProfileDescription',
    isChinese
        ? '选择整套组件风格、页面排布与交互外观。'
        : 'Choose a complete component, arrangement, and interaction system.',
  );
  String get layoutLoading =>
      localized('layoutLoading', isChinese ? '正在加载布局…' : 'Loading layouts…');
  String get layoutCommitting =>
      localized('layoutCommitting', isChinese ? '正在保存布局…' : 'Saving layout…');
  String get currentLayout =>
      localized('currentLayout', isChinese ? '当前布局' : 'Current layout');
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

  String get appearancePresetDirectory => localized(
    'appearancePresetDirectory',
    isChinese ? '主题目录' : 'Theme directory',
  );
  String invalidPresetConfigs(int count) =>
      isChinese ? '$count 个主题配置无效' : '$count invalid theme configurations';
  String get portableData => localized(
    'portableData',
    isChinese ? 'LicoUp 数据目录' : 'LicoUp Data Directory',
  );
  String dataHomeSource(String source) => switch (source) {
    'explicitEnvironment' =>
      isChinese ? '由 LICOUP_HOME 环境变量指定' : 'Set by LICOUP_HOME',
    'legacyEnvironment' =>
      isChinese
          ? '由已发布的 LICOUP_PORTABLE_DIR 别名指定'
          : 'Set by the published LICOUP_PORTABLE_DIR alias',
    'saved' => isChinese ? '已保存的位置' : 'Saved location',
    'mobileSandbox' => isChinese ? '应用沙盒' : 'Application sandbox',
    'testOverride' => isChinese ? '测试目录' : 'Test directory',
    _ => isChinese ? '默认位置' : 'Default location',
  };
  String get moveDataHome =>
      localized('moveDataHome', isChinese ? '移动数据目录' : 'Move data folder');
  String get moveDataHomeDescription => localized(
    'moveDataHomeDescription',
    isChinese
        ? '选择新位置后，客户端会先停止写入，再复制应用数据。原目录会保留。'
        : 'Choose a destination. LicoUp will stop its writers before copying. The original folder stays in place.',
  );
  String get dataHomeMoveRequiresSavedSelection => localized(
    'dataHomeMoveRequiresSavedSelection',
    isChinese
        ? '环境变量指定的位置和移动设备沙盒由其各自的设置管理，不能在此移动。'
        : 'Environment-selected locations and mobile sandbox data are managed by their respective settings.',
  );
  String get chooseDataHomeDestination => localized(
    'chooseDataHomeDestination',
    isChinese ? '选择目标文件夹' : 'Choose destination folder',
  );
  String get confirmDataHomeMove => localized(
    'confirmDataHomeMove',
    isChinese ? '移动 LicoUp 数据？' : 'Move LicoUp data?',
  );
  String dataHomeMoveConfirmation(String folder) => isChinese
      ? '将在“$folder”中创建 LicoUp 文件夹并复制当前数据。迁移成功后，客户端会继续使用新位置，原目录仍会保留。'
      : 'LicoUp will create a LicoUp folder inside “$folder”, copy the current data, and continue from the new location. The original folder will remain.';
  String get move => localized('move', isChinese ? '移动' : 'Move');
  String get dismiss => localized('dismiss', isChinese ? '关闭' : 'Dismiss');
  String get dataHomeMoveTitle => localized(
    'dataHomeMoveTitle',
    isChinese ? '正在移动 LicoUp 数据' : 'Moving LicoUp data',
  );
  String get dataHomeMoveSourcePreserved => localized(
    'dataHomeMoveSourcePreserved',
    isChinese
        ? '原目录会保留，直到你明确选择清理。'
        : 'The original folder stays in place until you choose to remove it.',
  );
  String dataHomePreviousRootRetained(String path) =>
      isChinese ? '已保留原目录：$path' : 'Original folder retained: $path';
  String get cleanPreviousDataHome => localized(
    'cleanPreviousDataHome',
    isChinese ? '将原目录移到废纸篓' : 'Move original folder to Trash',
  );
  String get confirmPreviousDataHomeCleanup => localized(
    'confirmPreviousDataHomeCleanup',
    isChinese ? '清理原数据目录？' : 'Move the original data folder to Trash?',
  );
  String dataHomeCleanupConfirmation(String path) => isChinese
      ? '“$path”将被移到系统废纸篓。当前 LicoUp 数据目录不会更改。'
      : '“$path” will be moved to the system Trash. Your current LicoUp data folder will not change.';
  String get cleaningPreviousDataHome => localized(
    'cleaningPreviousDataHome',
    isChinese ? '正在清理原数据目录' : 'Cleaning the original data folder',
  );
  String get dataHomeRecoveryTitle => localized(
    'dataHomeRecoveryTitle',
    isChinese ? '找不到已保存的数据目录' : 'Saved data folder not found',
  );
  String get dataHomeRecoveryDescription => localized(
    'dataHomeRecoveryDescription',
    isChinese
        ? 'LicoUp 不会创建空目录替代原数据。请重新连接原位置并重试，或选择一个已有的 LicoUp 数据目录。'
        : 'LicoUp will not replace your data with an empty folder. Reconnect the saved location and retry, or choose an existing LicoUp data folder.',
  );
  String get chooseExistingDataHome => localized(
    'chooseExistingDataHome',
    isChinese ? '选择已有数据目录' : 'Choose existing data folder',
  );
  String get confirmDataHomeRecovery => localized(
    'confirmDataHomeRecovery',
    isChinese ? '使用此数据目录？' : 'Use this data folder?',
  );
  String get dataHomeRecoveryConfirmation => localized(
    'dataHomeRecoveryConfirmation',
    isChinese
        ? '此现有目录将成为 LicoUp 的数据位置。请确认它包含你要继续使用的数据。'
        : 'This existing folder will become LicoUp’s data location. Confirm that it contains the data you want to use.',
  );
  String dataHomeRecoveryFailed(String _) => isChinese
      ? '恢复失败，已保存的数据位置仍不可用，LicoUp 没有创建空目录。请重试或选择包含数据的现有目录。'
      : 'Recovery failed. The saved location is still unavailable, and LicoUp did not create an empty folder. Retry or choose an existing folder that contains your data.';
  String get useThisFolder =>
      localized('useThisFolder', isChinese ? '使用此文件夹' : 'Use this folder');
  String dataHomeOperationTitle(String operation) => switch (operation) {
    'cleanup' => cleaningPreviousDataHome,
    'recovery' => isChinese ? '正在恢复 LicoUp 数据' : 'Recovering LicoUp data',
    _ => dataHomeMoveTitle,
  };
  String dataHomeMovePhase(String phase) => switch (phase) {
    'stopping-writers' =>
      isChinese ? '正在停止应用写入进程…' : 'Stopping application writers…',
    'stopping-conversation-host' =>
      isChinese ? '正在排空会话主机…' : 'Draining the conversation host…',
    'stopping-mcp-service' =>
      isChinese ? '正在停止 MCP 服务…' : 'Stopping the MCP service…',
    'stopping-gateway' => isChinese ? '正在停止网关…' : 'Stopping the Gateway…',
    'waiting-for-native-access' =>
      isChinese
          ? '正在等待其他 LicoUp 进程释放数据目录…'
          : 'Waiting for other LicoUp processes to release the data root…',
    'copying-data' => isChinese ? '正在复制应用数据…' : 'Copying application data…',
    'publishing-data' =>
      isChinese ? '正在完成新目录…' : 'Finalizing the copied folder…',
    'updating-owned-references' =>
      isChinese ? '正在更新应用管理的路径引用…' : 'Updating app-managed path references…',
    'switching-data-home' =>
      isChinese ? '正在切换数据位置…' : 'Switching to the new location…',
    'cleaning-previous-root' =>
      isChinese
          ? '正在将原目录移到系统废纸篓…'
          : 'Moving the original folder to the system Trash…',
    'recovering-root' =>
      isChinese ? '正在恢复数据位置…' : 'Recovering the data location…',
    'complete' => isChinese ? '正在重新载入客户端…' : 'Reloading the client…',
    _ => isChinese ? '正在准备迁移…' : 'Preparing the move…',
  };
  String dataHomeOperationFailed(
    String operation,
    String code,
  ) => switch (code) {
    'data_home_destination_exists' ||
    'data_home_destination_nested' ||
    'data_home_destination_invalid' ||
    'data_home_destination_unavailable' =>
      isChinese
          ? '目标位置不可用或已包含数据。当前数据位置未更改，请选择其他目标文件夹后重试。'
          : 'Choose another destination folder and try again. The current data folder was not changed.',
    'data_home_copy_failed' || 'data_home_copy_unsupported_entry' =>
      isChinese
          ? '复制未完成，当前数据位置未更改，原数据仍保留。请检查目标磁盘空间和文件访问权限后重试。'
          : 'The copy did not finish, and the current data folder was not changed. Your original data remains. Check the destination space and file access, then retry.',
    'data_home_relocation_recovery_required' ||
    'data_home_recovery_autostart_failed' =>
      isChinese
          ? '数据副本和原数据都已保留。新位置可能已经生效；请查看设置中显示的当前数据位置，并检查已启用的自启动项。'
          : 'Both data folders were preserved, and the new location may already be active. Check the current folder shown in Settings and review enabled startup items.',
    'data_home_previous_root_cleanup_failed' =>
      isChinese
          ? '未能将原目录移到废纸篓。当前数据位置未更改，原目录仍保留；你可以稍后重试。'
          : 'The original folder could not be moved to Trash. The active data folder is unchanged, and the original remains available to retry later.',
    'data_home_previous_root_marker_cleanup_failed' =>
      isChinese
          ? '原目录已移到废纸篓，但 LicoUp 未能清除保存的清理记录。当前数据位置未更改。'
          : 'The original folder was moved to Trash, but LicoUp could not clear its saved cleanup record. The active data folder is unchanged.',
    _ when operation == 'cleanup' =>
      isChinese
          ? '清理未完成，当前数据位置未更改，原目录仍保留。请稍后重试。'
          : 'Cleanup did not finish. The current data folder is unchanged and the original remains available to retry later.',
    _ when operation == 'recovery' =>
      isChinese
          ? '恢复未完成，原有选择未更改，也没有创建空目录。请重新连接原位置并重试，或选择包含数据的现有目录。'
          : 'Recovery did not finish, the saved selection was not changed, and no empty folder was created. Reconnect the original location or choose an existing data folder, then retry.',
    _ =>
      isChinese
          ? '移动未完成，当前数据位置未更改，原数据仍保留。请检查目标文件夹后重试。'
          : 'The move did not finish, and the current data folder was not changed. Your original data remains. Check the destination and retry.',
  };
  String get clientLogs =>
      localized('clientLogs', isChinese ? '客户端日志' : 'Client Logs');
  String get exportLogs =>
      localized('exportLogs', isChinese ? '导出日志' : 'Export Logs');
  String get exportLogsDescription => localized(
    'exportLogsDescription',
    isChinese
        ? '导出最近的客户端运行日志，用于诊断与问题反馈。'
        : 'Export recent client runtime logs for diagnostics and support.',
  );
  String get exportingLogs =>
      localized('exportingLogs', isChinese ? '正在导出日志...' : 'Exporting logs...');
  String get conversationArchiveRoot => localized(
    'conversationArchiveRoot',
    isChinese ? 'LicoUp 备份目录' : 'LicoUp Backup Directory',
  );
  String get snapshotRootPath =>
      localized('snapshotRootPath', isChinese ? '快照根路径' : 'Snapshot Root Path');
  String get save => localized('save', isChinese ? '保存' : 'Save');
  String get recommendedPlugins => localized(
    'recommendedPlugins',
    isChinese ? '推荐插件' : 'Recommended Plugins',
  );

  String get secureMesh =>
      localized('secureMesh', isChinese ? '安全网格' : 'Secure Mesh');
  String get refresh => localized('refresh', isChinese ? '刷新' : 'Refresh');
  String get protocol => localized('protocol', isChinese ? '协议' : 'Protocol');
  String get pairwise => localized('pairwise', isChinese ? '点对点' : 'Pairwise');
  String get file => localized('file', isChinese ? '文件' : 'File');
  String get fileRoute =>
      localized('fileRoute', isChinese ? '文件路由' : 'File Route');
  String get fileSync =>
      localized('fileSync', isChinese ? '文件同步' : 'File Sync');
  String get fileSyncHint => localized(
    'fileSyncHint',
    isChinese
        ? '选择文件与目标目录，评估路由后需本地确认才会写入。不会自动预览或入库。'
        : 'Pick a file and destination, evaluate the route, then confirm locally before write. No auto-preview or ingestion.',
  );
  String get chooseFile =>
      localized('chooseFile', isChinese ? '选择文件' : 'Choose File');
  String get chooseDestination => localized(
    'chooseDestination',
    isChinese ? '选择目标目录' : 'Choose Destination',
  );
  String get prepareFileSync =>
      localized('prepareFileSync', isChinese ? '准备同步' : 'Prepare Sync');
  String get fileSyncSize =>
      localized('fileSyncSize', isChinese ? '大小' : 'Size');
  String get destination =>
      localized('destination', isChinese ? '目标目录' : 'Destination');
  String get notSelected =>
      localized('notSelected', isChinese ? '未选择' : 'Not selected');
  String get fileSyncConfirmationPrompt => localized(
    'fileSyncConfirmationPrompt',
    isChinese
        ? '确认将文件写入所选目标目录？写入前不会自动打开或解析内容。'
        : 'Confirm writing this file into the selected destination? Content is not auto-opened or ingested before write.',
  );
  String get confirmWrite =>
      localized('confirmWrite', isChinese ? '确认写入' : 'Confirm Write');
  String get rejectWrite =>
      localized('rejectWrite', isChinese ? '拒绝写入' : 'Reject Write');
  String get fileSyncQueue =>
      localized('fileSyncQueue', isChinese ? '传输队列' : 'Transfer Queue');
  String get fileSyncStatusDrafting =>
      localized('fileSyncStatusDrafting', isChinese ? '起草中' : 'Drafting');
  String get fileSyncStatusEvaluating =>
      localized('fileSyncStatusEvaluating', isChinese ? '评估中' : 'Evaluating');
  String get fileSyncStatusAwaitingConfirmation => localized(
    'fileSyncStatusAwaitingConfirmation',
    isChinese ? '等待确认' : 'Awaiting confirmation',
  );
  String get fileSyncStatusConfirmed =>
      localized('fileSyncStatusConfirmed', isChinese ? '已确认' : 'Confirmed');
  String get fileSyncStatusRejected =>
      localized('fileSyncStatusRejected', isChinese ? '已拒绝' : 'Rejected');
  String get fileSyncStatusFailed =>
      localized('fileSyncStatusFailed', isChinese ? '失败' : 'Failed');
  String get remoteApproval =>
      localized('remoteApproval', isChinese ? '远程审批' : 'Remote Approval');
  String get remoteApprovalHint => localized(
    'remoteApprovalHint',
    isChinese
        ? '来自可信客户端的加密审批请求会出现在此收件箱。详情保持密文，仅显示摘要。'
        : 'Encrypted approval requests from trusted clients appear here. Detail stays ciphertext; only the summary is shown.',
  );
  String get remoteApprovalEmpty => localized(
    'remoteApprovalEmpty',
    isChinese ? '当前没有待处理的审批。' : 'No pending approvals.',
  );
  String get remoteApprovalHistory => localized(
    'remoteApprovalHistory',
    isChinese ? '审批历史' : 'Approval History',
  );
  String get remoteApprovalStatusPending =>
      localized('remoteApprovalStatusPending', isChinese ? '待处理' : 'Pending');
  String get remoteApprovalStatusAllowed =>
      localized('remoteApprovalStatusAllowed', isChinese ? '已批准' : 'Allowed');
  String get remoteApprovalStatusDenied =>
      localized('remoteApprovalStatusDenied', isChinese ? '已拒绝' : 'Denied');
  String get remoteApprovalStatusExpired =>
      localized('remoteApprovalStatusExpired', isChinese ? '已过期' : 'Expired');
  String get remoteApprovalStatusFailed =>
      localized('remoteApprovalStatusFailed', isChinese ? '失败' : 'Failed');
  String get risk => localized('risk', isChinese ? '风险' : 'Risk');
  String get summary => localized('summary', isChinese ? '摘要' : 'Summary');
  String get tools => localized('tools', isChinese ? '工具' : 'Tools');
  String get allow => localized('allow', isChinese ? '允许' : 'Allow');
  String get deny => localized('deny', isChinese ? '拒绝' : 'Deny');
  String get sourceAgent =>
      localized('sourceAgent', isChinese ? '源智能体' : 'Source Agent');
  String get targetAgent =>
      localized('targetAgent', isChinese ? '目标智能体' : 'Target Agent');
  String get packageDigest =>
      localized('packageDigest', isChinese ? '包摘要' : 'Package Digest');
  String get fileReceiveDestination => localized(
    'fileReceiveDestination',
    isChinese ? '文件接收位置' : 'File Receive Destination',
  );
  String get evaluatingFileReceiveDestination => localized(
    'evaluatingFileReceiveDestination',
    isChinese
        ? '正在评估安全网格文件接收位置。'
        : 'Evaluating Secure Mesh file receive destination.',
  );
  String get fileReceiveDestinationEvaluated => localized(
    'fileReceiveDestinationEvaluated',
    isChinese
        ? '安全网格文件接收位置已评估。'
        : 'Secure Mesh file receive destination evaluated.',
  );
  String get fileReceiveDestinationEvaluationFailed => localized(
    'fileReceiveDestinationEvaluationFailed',
    isChinese
        ? '安全网格文件接收位置评估失败。'
        : 'Secure Mesh file receive destination evaluation failed.',
  );
  String get command => localized('command', isChinese ? '命令' : 'Command');
  String get deviceTrust =>
      localized('deviceTrust', isChinese ? '设备信任' : 'Device Trust');
  String get trustPolicy =>
      localized('trustPolicy', isChinese ? '信任策略' : 'Trust Policy');
  String get adapter => localized('adapter', isChinese ? '适配器' : 'Adapter');
  String get readiness =>
      localized('readiness', isChinese ? '就绪状态' : 'Readiness');
  String get e2eeReadiness =>
      localized('e2eeReadiness', isChinese ? '端到端加密就绪' : 'E2EE Readiness');
  String get secretStore =>
      localized('secretStore', isChinese ? '密钥存储' : 'Secret Store');
  String get station => localized('station', isChinese ? '中转站' : 'Station');
  String get saveStation =>
      localized('saveStation', isChinese ? '保存中转站' : 'Save Station');
  String get defaultLabel =>
      localized('defaultLabel', isChinese ? 'Lico' : 'Lico');
  String get planDocumentTitle =>
      localized('planDocumentTitle', isChinese ? '计划文档' : 'Plan document');
  String get planDocumentEmpty => localized(
    'planDocumentEmpty',
    isChinese ? '尚未写入计划内容。' : 'No plan content yet.',
  );
  String get planDocumentUnavailable => localized(
    'planDocumentUnavailable',
    isChinese ? '无法读取计划文件。' : 'The plan file could not be read.',
  );
  String get active => localized('active', isChinese ? '当前' : 'Active');
  String get pairing =>
      localized('pairing', isChinese ? '通信' : 'Communication');
  String get tapToGeneratePairingQr => localized(
    'tapToGeneratePairingQr',
    isChinese ? '点击生成配对码' : 'Tap to generate pairing code',
  );
  String get pairingQrPlaceholder => localized(
    'pairingQrPlaceholder',
    isChinese ? '配对二维码' : 'Pairing QR code',
  );
  String get deviceTrustVerification => localized(
    'deviceTrustVerification',
    isChinese ? '设备信任验证' : 'Device Trust Verification',
  );
  String get trustVerified => localized(
    'trustVerified',
    isChinese ? '已验证，可发送加密内容' : 'Verified — protected send enabled',
  );
  String get trustUnverified => localized(
    'trustUnverified',
    isChinese ? '尚未验证，已阻止发送' : 'Unverified — protected send blocked',
  );
  String get trustKeyChanged => localized(
    'trustKeyChanged',
    isChinese ? '密钥已变化，必须重新验证' : 'Key changed — verification required',
  );
  String get trustRevoked => localized(
    'trustRevoked',
    isChinese ? '信任已撤销，已阻止发送' : 'Trust revoked — protected send blocked',
  );
  String get safetyNumber => localized(
    'safetyNumber',
    isChinese ? '60 位安全码' : '60-Digit Safety Number',
  );
  String get localFingerprint =>
      localized('localFingerprint', isChinese ? '本机指纹' : 'Local Fingerprint');
  String get peerFingerprint =>
      localized('peerFingerprint', isChinese ? '对端指纹' : 'Peer Fingerprint');
  String get verificationMethod => localized(
    'verificationMethod',
    isChinese ? '验证方式' : 'Verification Method',
  );
  String get securityCapabilities => localized(
    'securityCapabilities',
    isChinese ? '安全能力' : 'Security Capabilities',
  );
  String get expandSecurityCapabilities => localized(
    'expandSecurityCapabilities',
    isChinese ? '展开安全能力' : 'Expand security capabilities',
  );
  String get collapseSecurityCapabilities => localized(
    'collapseSecurityCapabilities',
    isChinese ? '收起安全能力' : 'Collapse security capabilities',
  );
  String get localEndpointCapabilities => localized(
    'localEndpointCapabilities',
    isChinese ? '本机能力集合' : 'Local Endpoint Capability Sets',
  );
  String get peerEndpointCapabilities => localized(
    'peerEndpointCapabilities',
    isChinese ? '对端能力集合' : 'Peer Endpoint Capability Sets',
  );
  String get negotiatedProtocolCapabilities => localized(
    'negotiatedProtocolCapabilities',
    isChinese ? '已协商协议能力' : 'Negotiated Protocol Capabilities',
  );
  String get enabledCapabilities =>
      localized('enabledCapabilities', isChinese ? '已启用' : 'Enabled');
  String get availableCapabilities =>
      localized('availableCapabilities', isChinese ? '可用' : 'Available');
  String get unavailableCapabilities =>
      localized('unavailableCapabilities', isChinese ? '不可用' : 'Unavailable');
  String get unverifiedCapabilities =>
      localized('unverifiedCapabilities', isChinese ? '未验证' : 'Unverified');
  String get missingMandatoryCapabilities => localized(
    'missingMandatoryCapabilities',
    isChinese ? '缺失的强制能力' : 'Missing Mandatory Capabilities',
  );
  String get capabilityReasons =>
      localized('capabilityReasons', isChinese ? '原因' : 'Reasons');
  String get selectedCustody =>
      localized('selectedCustody', isChinese ? '已选择的密钥托管' : 'Selected Custody');
  String get custodyRestartSemantics => localized(
    'custodyRestartSemantics',
    isChinese ? '重启后的安全语义' : 'Restart Security Semantics',
  );
  String get enabledCustodyHardening => localized(
    'enabledCustodyHardening',
    isChinese ? '已启用的托管加固' : 'Enabled Custody Hardening',
  );
  String get capabilityDependencies => localized(
    'capabilityDependencies',
    isChinese ? '能力依赖关系' : 'Capability Dependencies',
  );
  String get noCapabilities =>
      localized('noCapabilities', isChinese ? '无' : 'None');
  String get compareSafetyNumber => localized(
    'compareSafetyNumber',
    isChinese
        ? '请在两台设备上逐组核对安全码或扫描验证二维码。任何一组不同都不要继续发送。'
        : 'Compare every group on both devices or scan the verification QR code. Do not send if any group differs.',
  );
  String get createCode =>
      localized('createCode', isChinese ? '创建配对码' : 'Create Code');
  String get copyPairingCode =>
      localized('copyPairingCode', isChinese ? '复制配对码' : 'Copy Pairing Code');
  String get pairingCodeCopied => localized(
    'pairingCodeCopied',
    isChinese ? '配对码已复制' : 'Pairing Code Copied',
  );
  String get oneTimePairingCode => localized(
    'oneTimePairingCode',
    isChinese ? '一次性配对码' : 'One-Time Pairing Code',
  );
  String get oneTimePairingCodeNotice => localized(
    'oneTimePairingCodeNotice',
    isChinese
        ? '此配对码只会展示一次。重新生成会清除当前码并创建全新的配对码。'
        : 'This pairing code is shown once. Regenerating clears it and creates a new code.',
  );
  String get scanPairingPrompt => localized(
    'scanPairingPrompt',
    isChinese
        ? '点击右上角扫描按钮，扫描 Mac 上的 LicoUp 配对二维码。'
        : 'Tap the scan button in the top-right corner to scan the LicoUp pairing QR code on your Mac.',
  );
  String get close => localized('close', isChinese ? '关闭' : 'Close');
  String get scanQrToPairPhone => localized(
    'scanQrToPairPhone',
    isChinese ? '扫描此二维码完成手机配对' : 'Scan This QR Code To Pair Your Phone',
  );
  String get status => localized('status', isChinese ? '状态' : 'Status');
  String get model => localized('model', isChinese ? '模型' : 'Model');
  String get reasoningEffort =>
      localized('reasoningEffort', isChinese ? '思考强度' : 'Reasoning Effort');
  String reasoningEffortOptionLabel(String value, String fallback) {
    return switch (value.trim().toLowerCase()) {
      '' => 'Auto',
      'low' => 'Low',
      'medium' => 'Medium',
      'high' => 'High',
      'xhigh' || 'extra_high' || 'extra high' => 'Extra High',
      'max' => 'Max',
      'ultra' => 'Ultra',
      'minimal' => 'Minimal',
      'none' => 'None',
      'off' => 'Off',
      'enabled' => 'Enabled',
      'disabled' => 'Disabled',
      _ => fallback,
    };
  }

  String get paired => localized('paired', isChinese ? '已配对' : 'Paired');
  String get waiting => localized('waiting', isChinese ? '等待中' : 'Waiting');
  String get pairingId =>
      localized('pairingId', isChinese ? '配对 ID' : 'Pairing ID');
  String get expires => localized('expires', isChinese ? '过期时间' : 'Expires');
  String get pairingCode =>
      localized('pairingCode', isChinese ? '配对码' : 'Pairing Code');
  String get relayStatus =>
      localized('relayStatus', isChinese ? '中转状态' : 'Relay Status');
  String get pairedComputer =>
      localized('pairedComputer', isChinese ? '配对电脑' : 'Paired Computer');
  String get arcDesktop =>
      localized('arcDesktop', isChinese ? 'Arc Desktop' : 'Arc Desktop');
  String get availableAgents =>
      localized('availableAgents', isChinese ? '可用智能体' : 'Available Agents');
  String get desktopAgents =>
      localized('desktopAgents', isChinese ? '电脑智能体' : 'Desktop Agents');
  String get secureRelay => localized(
    'secureRelay',
    isChinese ? '通过电脑安全中转' : 'Secure Relay Through Computer',
  );
  String get noDesktopAgents => localized(
    'noDesktopAgents',
    isChinese ? '这台电脑暂未回显可用智能体。' : 'No desktop agents are available yet.',
  );
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

  String get conversationId =>
      localized('conversationId', isChinese ? '会话 ID' : 'Conversation ID');
  String get conversationIdCopied => localized(
    'conversationIdCopied',
    isChinese ? '会话 ID 已复制' : 'Conversation ID copied',
  );
  String get conversationCopyMessage =>
      localized('conversationCopyMessage', isChinese ? '复制消息' : 'Copy message');
  String get conversationMessageCopied => localized(
    'conversationMessageCopied',
    isChinese ? '消息已复制' : 'Message copied',
  );
  String get edit => localized('edit', isChinese ? '编辑' : 'Edit');
  String get llmGatewayLaunchAtLogin => localized(
    'llmGatewayLaunchAtLogin',
    isChinese ? '开机自启动' : 'Launch at login',
  );
  String get llmGatewayLaunchAtLoginDisabled => localized(
    'llmGatewayLaunchAtLoginDisabled',
    isChinese ? '已关闭开机自启动。' : 'Launch at login disabled.',
  );
  String get llmGatewayLaunchAtLoginEnabled => localized(
    'llmGatewayLaunchAtLoginEnabled',
    isChinese ? '已开启开机自启动。' : 'Launch at login enabled.',
  );
  String get llmGatewayLaunchAtLoginFailed => localized(
    'llmGatewayLaunchAtLoginFailed',
    isChinese ? '开机自启动未能更新。' : 'Launch at login could not be updated.',
  );
  String get llmGatewayLaunchAtLoginHint => localized(
    'llmGatewayLaunchAtLoginHint',
    isChinese
        ? '登录后单独启动 Gateway（不加载 API Key；授权仍在应用内完成）'
        : 'Start the Gateway alone after login (no API keys; authorize in the app)',
  );
  String get llmGatewayLaunchAtLoginUnsupported => localized(
    'llmGatewayLaunchAtLoginUnsupported',
    isChinese
        ? '当前系统不支持 Gateway 开机自启动。'
        : 'Launch at login is not supported on this system.',
  );
  String get startupAutostartHint => localized(
    'startupAutostartHint',
    isChinese
        ? '登录后自动启动桌面客户端与可选后台进程；Gateway 启动时不加载 API Key。'
        : 'Start the desktop client and optional helpers at login. Gateway starts without API keys.',
  );
  String get startupAutostartLoadFailed => localized(
    'startupAutostartLoadFailed',
    isChinese ? '无法读取自启动状态。' : 'Could not load auto-start status.',
  );
  String get startupAutostartSaveFailed => localized(
    'startupAutostartSaveFailed',
    isChinese ? '自启动设置未能更新。' : 'Auto-start settings could not be updated.',
  );
  String get startupAutostartSaved => localized(
    'startupAutostartSaved',
    isChinese ? '自启动设置已保存。' : 'Auto-start settings saved.',
  );
  String get startupAutostartTitle => localized(
    'startupAutostartTitle',
    isChinese ? '开启自启动' : 'Enable auto-start',
  );
  String get startupAutostartUnsupported => localized(
    'startupAutostartUnsupported',
    isChinese
        ? '当前系统不支持登录自启动。'
        : 'Login auto-start is not supported on this system.',
  );
  String get startupBackgroundSection => localized(
    'startupBackgroundSection',
    isChinese ? '后台进程' : 'Background processes',
  );
  String get startupDesktopClientAutostart => localized(
    'startupDesktopClientAutostart',
    isChinese ? '登录时启动桌面客户端' : 'Launch desktop client at login',
  );
  String get startupDesktopClientSection => localized(
    'startupDesktopClientSection',
    isChinese ? '桌面客户端' : 'Desktop client',
  );
  String get startupGatewayHint => localized(
    'startupGatewayHint',
    isChinese
        ? '登录后单独启动 Gateway（不加载 API Key；授权仍在应用内完成）'
        : 'Start the Gateway alone after login (no API keys; authorize in the app)',
  );
  String get startupLocalMcpHint => localized(
    'startupLocalMcpHint',
    isChinese
        ? '登录时校验打包的本地 MCP 二进制；不会静默安装智能体 MCP'
        : 'Verify packaged local MCP binaries at login; never silently install agent MCP',
  );
  String get startupLocalMcpServices => localized(
    'startupLocalMcpServices',
    isChinese ? '本地 MCP 服务' : 'Local MCP services',
  );
  String get startupSilentStart =>
      localized('startupSilentStart', isChinese ? '静默启动' : 'Silent start');
  String get startupSilentStartHint => localized(
    'startupSilentStartHint',
    isChinese ? '启动后自动最小化，不展示界面' : 'Start minimized without showing the window',
  );
  String get agentHubVisitOfficial =>
      localized('agentHubVisitOfficial', isChinese ? '访问官网' : 'Visit site');
  String get agentHubRefresh =>
      localized('agentHubRefresh', isChinese ? '刷新' : 'Refresh');
  String get pluginManagementRefresh => localized(
    'pluginManagementRefresh',
    isChinese ? '刷新插件目录' : 'Refresh plugin catalog',
  );
  String get agentHubLatest => localized('agentHubLatest', 'latest');
  String get agentHubPackageManager => localized(
    'agentHubPackageManager',
    isChinese ? '包管理器' : 'Package manager',
  );
  String get agentHubVersion =>
      localized('agentHubVersion', isChinese ? '版本' : 'Version');
  String agentHubUninstallTypeConfirm(String name) =>
      isChinese ? '请输入 $name 以确认' : 'Type $name to confirm';
  String get agentHubInstallTitle =>
      localized('agentHubInstallTitle', isChinese ? '安装智能体' : 'Install agent');
  String agentHubInstallProgressTitle(String name) =>
      isChinese ? '正在安装 $name' : 'Installing $name';
  String get agentHubInstallProgressHint => localized(
    'agentHubInstallProgressHint',
    isChinese
        ? '正在下载并安装，可能需要几分钟。'
        : 'Downloading and installing — this can take a few minutes.',
  );
  String get agentHubInstallFailedHint => localized(
    'agentHubInstallFailedHint',
    isChinese ? '安装失败，请重试。' : 'Installation failed. Please try again.',
  );
  String get agentHubDownloadSource => localized(
    'agentHubDownloadSource',
    isChinese ? '下载源' : 'Download source',
  );
  String get agentHubPendingCommand => localized(
    'agentHubPendingCommand',
    isChinese ? '即将执行的命令' : 'Command to run',
  );

  // Selection facts and the adopted selection policy.
  String get selectionFactsTitle =>
      localized('selectionFactsTitle', isChinese ? '选择依据' : 'Selection facts');
  String selectionFactsCaption(String agent) => isChinese
      ? '按维度说明为何选择 $agent 的候选路线。'
      : 'Why $agent\u2019s candidate route was selected, by dimension.';
  String get selectionFactsLoading => localized(
    'selectionFactsLoading',
    isChinese ? '正在读取选择依据…' : 'Loading selection facts…',
  );
  String get selectionFactsEmpty => localized(
    'selectionFactsEmpty',
    isChinese
        ? '尚未记录该 Agent 的选择依据。'
        : 'No selection facts were recorded for this Agent.',
  );
  String get selectionSupport =>
      localized('selectionSupport', isChinese ? '支持' : 'Support');
  String get selectionAvailability =>
      localized('selectionAvailability', isChinese ? '可用性' : 'Availability');
  String get selectionCredentials =>
      localized('selectionCredentials', isChinese ? '凭据' : 'Credential');

  String get selectionPolicyTitle => localized(
    'selectionPolicyTitle',
    isChinese ? '路线选择策略' : 'Route selection policy',
  );
  String get selectionPolicyUnadopted => localized(
    'selectionPolicyUnadopted',
    isChinese ? '尚未采纳任何策略' : 'No policy is adopted',
  );
  String get selectionPolicyRevisionInForce => localized(
    'selectionPolicyRevisionInForce',
    isChinese ? '生效版本' : 'Revision in force',
  );
  String get selectionPolicySuggestions => localized(
    'selectionPolicySuggestions',
    isChinese ? '待决建议' : 'Suggestions',
  );
  String get selectionPolicyNoSuggestions => localized(
    'selectionPolicyNoSuggestions',
    isChinese ? '当前没有可采纳的建议。' : 'There is no suggestion to adopt right now.',
  );
  String get selectionPolicyEvaluatorLabel => localized(
    'selectionPolicyEvaluatorLabel',
    isChinese ? '评估 Agent' : 'Evaluating Agent',
  );
  String get selectionPolicyEvidenceLimitsLabel => localized(
    'selectionPolicyEvidenceLimitsLabel',
    isChinese ? '证据范围' : 'Evidence limits',
  );
  String get selectionPolicyRationaleLabel => localized(
    'selectionPolicyRationaleLabel',
    isChinese ? '理由' : 'Rationale',
  );
  String get selectionPolicyEffectsLabel => localized(
    'selectionPolicyEffectsLabel',
    isChinese ? '预期影响' : 'Proposed effects',
  );
  String get selectionPolicyEvidenceDigestLabel => localized(
    'selectionPolicyEvidenceDigestLabel',
    isChinese ? '证据摘要' : 'Evidence digest',
  );
  String get selectionPolicyRoutingOnlyNote => localized(
    'selectionPolicyRoutingOnlyNote',
    isChinese
        ? '该样本仅测量了候选顺序，不构成上下文或协作方面的改进。'
        : 'This sample measured candidate order only; it is not a context or '
              'collaboration improvement.',
  );
  String get selectionPolicyInvalidated => localized(
    'selectionPolicyInvalidated',
    isChinese ? '已被更新的结果作废' : 'Invalidated by a newer outcome',
  );
  String get selectionPolicyAdopt =>
      localized('selectionPolicyAdopt', isChinese ? '采纳' : 'Adopt');
  String get selectionPolicyDismiss =>
      localized('selectionPolicyDismiss', isChinese ? '忽略' : 'Dismiss');
  String get selectionPolicyRevoke => localized(
    'selectionPolicyRevoke',
    isChinese ? '撤销已采纳策略' : 'Revoke adopted policy',
  );
  String selectionPolicyRefused(String reasonCode) =>
      isChinese ? '未能完成：$reasonCode' : 'Not applied: $reasonCode';
  String get selectionPolicyOwnerAbsent => localized(
    'selectionPolicyOwnerAbsent',
    isChinese
        ? '此版本未组合策略所有者，未做任何更改。'
        : 'This build composes no policy owner; nothing was changed.',
  );
  String get selectionPolicyKeptCurrent => localized(
    'selectionPolicyKeptCurrent',
    isChinese
        ? '已忽略该建议，当前策略保持不变。'
        : 'The suggestion was dismissed; the current policy stays in force.',
  );
}
