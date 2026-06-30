part of 'future_client_controller.dart';

extension FutureClientConversationArchiveActions on FutureClientController {
  Future<void> archiveConversationKeywords({
    String? keywords,
    String? path,
  }) async {
    final trimmedKeywords = (keywords ?? archiveKeywordsController.text).trim();
    final trimmedPath = (path ?? archiveDestinationController.text).trim();
    if (trimmedKeywords.isEmpty ||
        trimmedPath.isEmpty ||
        isCollectingConversationArchive) {
      return;
    }
    isCollectingConversationArchive = true;
    lastError = '';
    statusMessage = '正在创建本机对话归档任务。';
    statusCaption = 'Conversation archive';
    _notifyStateChanged();
    try {
      final created = await conversationService.createArchiveJob(
        agentService: agentService,
        keywords: trimmedKeywords,
        path: trimmedPath,
      );
      final jobId = (created['jobId'] ?? '').toString();
      selectedConversationArchiveJobId = jobId;
      conversationArchiveWorkflowEvents = _archiveJobEvents(created);
      scannedTargets = _targetCandidatesFromArchiveJob(created);
      _selectDefaultConversationAgent();
      conversationArchiveResult = _conversationArchiveResultFromJob(
        created,
        requestedKeywords: trimmedKeywords,
        requestedPath: trimmedPath,
      );
      conversationArchiveReport = null;
      final scan = created['targetScanSummary'] is Map
          ? Map<String, dynamic>.from(created['targetScanSummary'] as Map)
          : const <String, dynamic>{};
      final clientCount = (scan['clientCount'] as num?)?.toInt() ?? 0;
      final detectedCount = (scan['detectedCount'] as num?)?.toInt() ?? 0;
      statusMessage = '已创建本机归档任务，扫描 $clientCount 个目标，$detectedCount 个可用，正在运行。';
      statusCaption = trimmedPath;
      _notifyStateChanged();
      unawaited(
        _drainConversationArchiveJob(jobId, requestedPath: trimmedPath),
      );
    } catch (error) {
      debugPrint('Failed to create native conversation archive job: $error');
      lastError = error.toString();
      statusMessage = '本机对话归档任务创建失败。';
      statusCaption = 'Conversation archive';
      isCollectingConversationArchive = false;
      _notifyStateChanged();
    }
  }

  Future<void> _drainConversationArchiveJob(
    String jobId, {
    required String requestedPath,
  }) async {
    if (jobId.trim().isEmpty) {
      isCollectingConversationArchive = false;
      _notifyStateChanged();
      return;
    }
    try {
      await conversationService.drainArchiveJobs(
        agentService: agentService,
        jobId: jobId,
      );
      await observeConversationArchiveJob(jobId, refreshCollections: true);
      _finishConversationArchiveJobStatus(requestedPath: requestedPath);
    } catch (error) {
      debugPrint('Failed to drain native conversation archive job: $error');
      lastError = error.toString();
      statusMessage = '本机对话归档任务运行失败。';
      statusCaption = 'Conversation archive';
    } finally {
      isCollectingConversationArchive = false;
      _notifyStateChanged();
    }
  }

  Future<void> observeConversationArchiveJob(
    String jobId, {
    bool refreshCollections = false,
    bool notify = true,
  }) async {
    final trimmed = jobId.trim();
    if (trimmed.isEmpty) {
      return;
    }
    final job = await conversationService.archiveJobStatus(
      agentService: agentService,
      jobId: trimmed,
    );
    final events = await conversationService.archiveJobEvents(
      agentService: agentService,
      jobId: trimmed,
    );
    final eventItems =
        ((events['events'] as List?) ?? (job['events'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .toList();
    selectedConversationArchiveJobId = trimmed;
    conversationArchiveWorkflowEvents = eventItems;
    conversationArchiveResult = _conversationArchiveResultFromJob(
      {...job, 'events': eventItems},
      requestedKeywords: archiveKeywordsController.text,
      requestedPath: archiveDestinationController.text,
    );
    conversationArchiveReport = job['validationResult'] is Map
        ? Map<String, dynamic>.from(job['validationResult'] as Map)
        : conversationArchiveReport;
    if (refreshCollections) {
      conversationSnapshotCollections = await conversationService
          .listSnapshotCollections(agentService: agentService);
    }
    if (notify) {
      _notifyStateChanged();
    }
  }

  Map<String, dynamic> _conversationArchiveResultFromJob(
    Map<String, dynamic> job, {
    required String requestedKeywords,
    required String requestedPath,
  }) {
    final request = job['request'] is Map
        ? Map<String, dynamic>.from(job['request'] as Map)
        : const <String, dynamic>{};
    final archiveResult = job['archiveResult'] is Map
        ? Map<String, dynamic>.from(job['archiveResult'] as Map)
        : <String, dynamic>{};
    final validationResult = job['validationResult'] is Map
        ? Map<String, dynamic>.from(job['validationResult'] as Map)
        : const <String, dynamic>{};
    final validation = validationResult['validation'] is Map
        ? Map<String, dynamic>.from(validationResult['validation'] as Map)
        : archiveResult['validation'];
    final status = (job['status'] ?? 'queued').toString();
    final path =
        (archiveResult['archiveRoot'] ?? request['path'] ?? requestedPath)
            .toString();
    final keywords = request['keywords'] ?? requestedKeywords;
    final result = <String, dynamic>{
      ...archiveResult,
      'ok': status == 'completed',
      'status': status,
      'phase': (job['phase'] ?? status).toString(),
      'jobId': (job['jobId'] ?? '').toString(),
      'mode': 'conversation-archive-job',
      'entry': 'keyword-archive-job',
      'keywords': keywords is List
          ? keywords
          : keywords
                .toString()
                .split(',')
                .map((value) => value.trim())
                .where((value) => value.isNotEmpty)
                .toList(),
      'archiveRoot': path,
      'targetScan': job['targetScanSummary'] ?? job['targetScan'],
      'workflow': job['workflow'],
      'workflowEvents': _archiveJobEvents(job),
      'nativeJob': job,
    };
    if (validation != null) {
      result['validation'] = validation;
    }
    return result;
  }

  List<Map<String, dynamic>> _archiveJobEvents(Map<String, dynamic> job) {
    return (job['events'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
  }

  List<TargetCandidate> _targetCandidatesFromArchiveJob(
    Map<String, dynamic> job,
  ) {
    final targetScan = job['targetScan'];
    if (targetScan is! Map) {
      return const [];
    }
    return (targetScan['candidates'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(TargetCandidate.fromJson)
        .toList();
  }

  void _finishConversationArchiveJobStatus({required String requestedPath}) {
    final result = conversationArchiveResult;
    if (result == null) {
      return;
    }
    final documentCount =
        (result['documentCount'] as num?)?.toInt() ??
        (result['selectedCount'] as num?)?.toInt() ??
        0;
    final archiveRoot = (result['archiveRoot'] ?? requestedPath).toString();
    final validation = result['validation'];
    final health = validation is Map
        ? (validation['healthStatus'] ?? 'unknown').toString()
        : '';
    final workflow = result['workflow'] is Map
        ? Map<String, dynamic>.from(result['workflow'] as Map)
        : <String, dynamic>{};
    final status = (workflow['status'] ?? result['status'] ?? '').toString();
    final lastError =
        (result['nativeJob'] is Map ? result['nativeJob']['lastError'] : '')
            .toString();
    if (status == 'completed') {
      statusMessage = health.isEmpty
          ? '已归档 $documentCount 条原生对话到目录。'
          : '已归档 $documentCount 条原生对话到目录，本机校验 $health。';
    } else if (status == 'failed') {
      statusMessage = lastError.isEmpty ? '本机对话归档任务失败。' : lastError;
    } else if (status == 'retry_scheduled') {
      statusMessage = '本机对话归档任务已安排重试。';
    } else {
      statusMessage = '本机对话归档任务状态：$status。';
    }
    statusCaption = archiveRoot;
  }

  Future<void> collectConversationArchive(String topic) async {
    final agent = selectedConversationAgent;
    final trimmedTopic = topic.trim();
    if (agent == null ||
        trimmedTopic.isEmpty ||
        isCollectingConversationArchive) {
      return;
    }
    isCollectingConversationArchive = true;
    lastError = '';
    statusMessage = '正在归档 ${agent.label} 相关原生对话。';
    statusCaption = 'Agent archive';
    _notifyStateChanged();
    try {
      final result = await conversationService.collectSnapshots(
        agentService: agentService,
        agentId: agent.target,
        topic: trimmedTopic,
      );
      conversationArchiveResult = result;
      conversationSnapshotCollections = await conversationService
          .listSnapshotCollections(agentService: agentService);
      final selectedCount = (result['selectedCount'] as num?)?.toInt() ?? 0;
      statusMessage = selectedCount == 0
          ? '已创建空归档集合。'
          : '已归档 $selectedCount 条原生对话。';
      statusCaption = 'Agent archive';
    } catch (error) {
      debugPrint('Failed to collect native conversation snapshots: $error');
      lastError = error.toString();
      statusMessage = '${agent.label} 对话归档失败。';
      statusCaption = 'Agent archive';
    } finally {
      isCollectingConversationArchive = false;
      _notifyStateChanged();
    }
  }

  Future<void> refreshConversationArchiveProfiles() async {
    try {
      conversationArchiveProfiles = await conversationService
          .listArchiveProfiles(agentService: agentService);
      if (selectedArchiveProfileId.isEmpty &&
          conversationArchiveProfiles.isNotEmpty) {
        selectedArchiveProfileId =
            (conversationArchiveProfiles.first['profileId'] ?? '').toString();
      }
      if (selectedArchiveProfileId.isNotEmpty &&
          !conversationArchiveProfiles.any(
            (profile) =>
                (profile['profileId'] ?? '').toString() ==
                selectedArchiveProfileId,
          )) {
        selectedArchiveProfileId = conversationArchiveProfiles.isEmpty
            ? ''
            : (conversationArchiveProfiles.first['profileId'] ?? '').toString();
      }
    } catch (error) {
      debugPrint('Failed to load conversation archive profiles: $error');
      lastError = error.toString();
    } finally {
      _notifyStateChanged();
    }
  }

  void selectConversationArchiveProfile(String profileId) {
    selectedArchiveProfileId = profileId.trim();
    _notifyStateChanged();
  }

  Future<void> runSelectedConversationArchiveProfile() async {
    final profileId = selectedArchiveProfileId.trim();
    if (profileId.isEmpty || isCollectingConversationArchive) {
      return;
    }
    isCollectingConversationArchive = true;
    lastError = '';
    statusMessage = '正在运行项目对话归档。';
    statusCaption = 'Project archive';
    _notifyStateChanged();
    try {
      final result = await conversationService.runArchiveProfile(
        agentService: agentService,
        profileId: profileId,
        trigger: 'manual',
      );
      conversationArchiveResult = result;
      conversationArchiveReport = result;
      conversationSnapshotCollections = await conversationService
          .listSnapshotCollections(agentService: agentService);
      final validation = result['validation'];
      final health = validation is Map
          ? (validation['healthStatus'] ?? 'unknown').toString()
          : 'unknown';
      final indexCount = (result['indexCount'] as num?)?.toInt() ?? 0;
      statusMessage = '项目归档完成：$indexCount 条，健康状态 $health。';
      statusCaption = 'Project archive';
    } catch (error) {
      debugPrint('Failed to run project conversation archive: $error');
      lastError = error.toString();
      statusMessage = '项目对话归档失败。';
      statusCaption = 'Project archive';
    } finally {
      isCollectingConversationArchive = false;
      _notifyStateChanged();
    }
  }

  Future<void> verifySelectedConversationArchiveProfile() async {
    final profileId = selectedArchiveProfileId.trim();
    if (profileId.isEmpty || isCollectingConversationArchive) {
      return;
    }
    isCollectingConversationArchive = true;
    lastError = '';
    statusMessage = '正在验证项目对话归档。';
    statusCaption = 'Project archive';
    _notifyStateChanged();
    try {
      final result = await conversationService.verifyArchiveProfile(
        agentService: agentService,
        profileId: profileId,
      );
      conversationArchiveResult = result;
      conversationArchiveReport = result;
      final validation = result['validation'];
      final health = validation is Map
          ? (validation['healthStatus'] ?? 'unknown').toString()
          : 'unknown';
      statusMessage = '项目归档验证完成：$health。';
      statusCaption = 'Project archive';
    } catch (error) {
      debugPrint('Failed to verify project conversation archive: $error');
      lastError = error.toString();
      statusMessage = '项目对话归档验证失败。';
      statusCaption = 'Project archive';
    } finally {
      isCollectingConversationArchive = false;
      _notifyStateChanged();
    }
  }

  Future<void> reportSelectedConversationArchiveProfile() async {
    final profileId = selectedArchiveProfileId.trim();
    if (profileId.isEmpty || isCollectingConversationArchive) {
      return;
    }
    isCollectingConversationArchive = true;
    lastError = '';
    statusMessage = '正在读取项目对话归档报告。';
    statusCaption = 'Project archive';
    _notifyStateChanged();
    try {
      final result = await conversationService.reportArchiveProfile(
        agentService: agentService,
        profileId: profileId,
      );
      conversationArchiveResult = result;
      conversationArchiveReport = result;
      statusMessage = '项目归档报告已读取。';
      statusCaption = 'Project archive';
    } catch (error) {
      debugPrint('Failed to load project conversation archive report: $error');
      lastError = error.toString();
      statusMessage = '项目对话归档报告读取失败。';
      statusCaption = 'Project archive';
    } finally {
      isCollectingConversationArchive = false;
      _notifyStateChanged();
    }
  }

  Future<void> refreshConversationSnapshotRoot() async {
    try {
      final result = await conversationService.getSnapshotRoot(
        agentService: agentService,
      );
      snapshotRootState = result;
      snapshotRootController.text = (result['snapshotRoot'] ?? '').toString();
      if (archiveDestinationController.text.trim().isEmpty) {
        archiveDestinationController.text = snapshotRootController.text;
      }
      conversationSnapshotCollections = await conversationService
          .listSnapshotCollections(agentService: agentService);
    } catch (error) {
      debugPrint('Failed to load snapshot root: $error');
      lastError = error.toString();
    } finally {
      _notifyStateChanged();
    }
  }

  Future<void> setConversationSnapshotRoot(String path) async {
    final trimmed = path.trim();
    if (trimmed.isEmpty || isSavingSnapshotRoot) {
      return;
    }
    isSavingSnapshotRoot = true;
    lastError = '';
    statusMessage = '正在更新对话归档目录。';
    statusCaption = 'Settings';
    _notifyStateChanged();
    try {
      final result = await conversationService.setSnapshotRoot(
        agentService: agentService,
        path: trimmed,
      );
      snapshotRootState = result;
      snapshotRootController.text = (result['snapshotRoot'] ?? trimmed)
          .toString();
      archiveDestinationController.text = snapshotRootController.text;
      conversationSnapshotCollections = await conversationService
          .listSnapshotCollections(agentService: agentService);
      statusMessage = result['ok'] == true
          ? '对话归档目录已更新。'
          : (result['message'] ?? '对话归档目录未更新。').toString();
      statusCaption = 'Settings';
    } catch (error) {
      debugPrint('Failed to set snapshot root: $error');
      lastError = error.toString();
      statusMessage = '对话归档目录更新失败。';
      statusCaption = 'Settings';
    } finally {
      isSavingSnapshotRoot = false;
      _notifyStateChanged();
    }
  }

  Future<void> refreshPreferredSnapshotCurator() async {
    try {
      final result = await conversationService.getPreferredSnapshotCurator(
        agentService: agentService,
      );
      preferredSnapshotCuratorState = result;
      final curator = result['preferredSnapshotCurator'];
      snapshotCuratorController.text = curator is Map
          ? (curator['target'] ?? '').toString()
          : '';
    } catch (error) {
      debugPrint('Failed to load preferred snapshot curator: $error');
      lastError = error.toString();
    } finally {
      _notifyStateChanged();
    }
  }

  Future<void> setPreferredSnapshotCurator(String target) async {
    if (isSavingSnapshotCurator) {
      return;
    }
    isSavingSnapshotCurator = true;
    lastError = '';
    statusMessage = '正在更新归档策展智能体。';
    statusCaption = 'Settings';
    _notifyStateChanged();
    try {
      final result = await conversationService.setPreferredSnapshotCurator(
        agentService: agentService,
        target: target,
      );
      preferredSnapshotCuratorState = result;
      final curator = result['preferredSnapshotCurator'];
      snapshotCuratorController.text = curator is Map
          ? (curator['target'] ?? '').toString()
          : '';
      statusMessage = result['status'] == 'cleared'
          ? '归档策展智能体已清除。'
          : '归档策展智能体已更新。';
      statusCaption = 'Settings';
    } catch (error) {
      debugPrint('Failed to set preferred snapshot curator: $error');
      lastError = error.toString();
      statusMessage = '归档策展智能体更新失败。';
      statusCaption = 'Settings';
    } finally {
      isSavingSnapshotCurator = false;
      _notifyStateChanged();
    }
  }

  Future<void> ensureSnapshotBridgeForSelectedAgent() async {
    final agent = selectedConversationAgent;
    if (agent == null || isCollectingConversationArchive) {
      return;
    }
    isCollectingConversationArchive = true;
    lastError = '';
    statusMessage = '正在确认 ${agent.label} 归档辅助桥接。';
    statusCaption = 'Agent archive';
    _notifyStateChanged();
    try {
      conversationArchiveResult = await conversationService
          .ensureSnapshotBridge(
            agentService: agentService,
            agentId: agent.target,
            configPath: agent.configPath ?? '',
          );
      statusMessage = conversationArchiveResult?['ok'] == true
          ? '${agent.label} 归档辅助桥接已就绪。'
          : (conversationArchiveResult?['message'] ?? '归档辅助桥接未更新。').toString();
      statusCaption = 'Agent archive';
    } catch (error) {
      debugPrint('Failed to ensure snapshot bridge: $error');
      lastError = error.toString();
      statusMessage = '${agent.label} 归档辅助桥接确认失败。';
      statusCaption = 'Agent archive';
    } finally {
      isCollectingConversationArchive = false;
      _notifyStateChanged();
    }
  }
}
