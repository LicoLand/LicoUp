part of 'package:flutter_client/src/application/controller/client_controller.dart';

extension ClientSkillHubActions on ClientController {
  Future<void> refreshSkillHub(String agent) async {
    await _runSkillHubAction(
      '正在扫描所有智能体的技能。',
      'Scanning skills loadable by local agents.',
      () async {
        var targets = scannedTargets;
        if (targets.isEmpty) {
          await scanTargets();
          targets = scannedTargets;
        }
        final detectedTargets = targets
            .where((t) => t.status != 'not-detected')
            .toList();
        final detectedAgentIds = detectedTargets
            .map((target) => target.target)
            .toList(growable: false);
        final skillCatalog = SkillHubSkillCatalogBuilder(
          detectedAgentIds: detectedAgentIds,
        );

        final isTesting = Platform.environment.containsKey('FLUTTER_TEST');
        if (!isTesting) {
          final home =
              Platform.environment['HOME'] ??
              Platform.environment['USERPROFILE'] ??
              '';
          await skillCatalog.scanLocalDirectories(
            workspaceRoot: Directory.current.path,
            homeDirectory: home,
            log: debugPrint,
          );
        }

        final pairingsFutures = detectedTargets.map((target) async {
          if (target.target == agent) {
            return await agentService.listPairings(agent: target.target);
          }
          try {
            return await agentService.listPairings(agent: target.target);
          } catch (_) {
            return const <Map<String, dynamic>>[];
          }
        });
        final pairingsLists = await Future.wait(pairingsFutures);
        final allPairings = <Map<String, dynamic>>[];
        for (final list in pairingsLists) {
          allPairings.addAll(list);
        }

        final skillsFutures = detectedTargets.map((target) async {
          if (target.target == agent) {
            final list = await agentService.listSkills(agent: target.target);
            return {'agentId': target.target, 'skills': list};
          }
          try {
            final list = await agentService.listSkills(agent: target.target);
            return {'agentId': target.target, 'skills': list};
          } catch (_) {
            return {
              'agentId': target.target,
              'skills': const <Map<String, dynamic>>[],
            };
          }
        });
        final skillsResults = await Future.wait(skillsFutures);

        for (final res in skillsResults) {
          final agentId = res['agentId'] as String;
          final list = res['skills'] as List<Map<String, dynamic>>;
          for (final skill in list) {
            skillCatalog.addOrMergeSkill(skill, agentId: agentId);
          }
        }

        skillCatalog.ensureAgentAttribution();

        skillHubPairings = allPairings;
        skillHubSkills = skillCatalog.skills.toList();

        skillHubActionResult = {
          'ok': true,
          'agent': agent,
          'pairings': allPairings.length,
          'skills': skillHubSkills.length,
        };
        _setLocalizedStatusMessage(
          '已扫描本机所有智能体的技能（共 ${skillHubSkills.length} 个技能）。',
          'Scanned ${skillHubSkills.length} skills loadable by local agents.',
        );
      },
    );
  }

  Future<void> requestSkillHubPairing(
    String agent, {
    String target = '',
  }) async {
    await _runSkillHubAction(
      '正在请求技能中心配对。',
      'Requesting Skill Hub pairing.',
      () async {
        skillHubActionResult = await agentService.requestPairing(
          agent: agent,
          target: target,
        );
        skillHubPairings = await agentService.listPairings(agent: agent);
        _setLocalizedStatusMessage(
          '已请求 $agent 配对。',
          'Requested pairing for $agent.',
        );
      },
    );
  }

  Future<void> approveSkillHubPairing(String agent) async {
    await _runSkillHubAction(
      '正在批准技能中心配对。',
      'Approving Skill Hub pairing.',
      () async {
        skillHubActionResult = await agentService.approvePairing(agent: agent);
        skillHubPairings = await agentService.listPairings(agent: agent);
        skillHubSkills = await agentService.listSkills(agent: agent);
        _setLocalizedStatusMessage(
          '已批准 $agent 配对。',
          'Approved pairing for $agent.',
        );
      },
    );
  }

  Future<void> revokeSkillHubPairing(String agent) async {
    await _runSkillHubAction(
      '正在撤销技能中心配对。',
      'Revoking Skill Hub pairing.',
      () async {
        skillHubActionResult = await agentService.revokePairing(agent: agent);
        skillHubPairings = await agentService.listPairings(agent: agent);
        skillHubSkills = const [];
        _setLocalizedStatusMessage(
          '已撤销 $agent 配对。',
          'Revoked pairing for $agent.',
        );
      },
    );
  }

  Future<void> previewSkillInstall({
    required String agent,
    required String url,
    String installRoot = '',
    String name = '',
    bool overwrite = false,
  }) async {
    await _runSkillHubAction(
      '正在读取 GitHub 技能包。',
      'Reading the GitHub skill package.',
      () async {
        skillInstallPlan = await agentService.planSkillInstall(
          agent: agent,
          url: url,
          installRoot: installRoot,
          name: name,
          overwrite: overwrite,
        );
        skillHubActionResult = skillInstallPlan;
        final skillId = (skillInstallPlan?['skillId'] ?? '').toString();
        final status = (skillInstallPlan?['status'] ?? '').toString();
        _setLocalizedStatusMessage(
          skillId.isEmpty ? '已生成技能安装计划。' : '已生成 $skillId 的技能安装计划：$status。',
          skillId.isEmpty
              ? 'Generated the skill install plan.'
              : 'Generated the skill install plan for $skillId: $status.',
        );
      },
    );
  }

  Future<void> installSkillFromGitHub({
    required String agent,
    required String url,
    String installRoot = '',
    String name = '',
    bool overwrite = false,
    bool pin = false,
  }) async {
    await _runSkillHubAction(
      '正在安装 GitHub 技能包。',
      'Installing the GitHub skill package.',
      () async {
        skillInstallResult = await agentService.applySkillInstall(
          agent: agent,
          url: url,
          installRoot: installRoot,
          name: name,
          overwrite: overwrite,
          pin: pin,
        );
        skillHubActionResult = skillInstallResult;
        skillHubPairings = await agentService.listPairings(agent: agent);
        skillHubSkills = await agentService.listSkills(agent: agent);
        final skillId = (skillInstallResult?['skillId'] ?? '').toString();
        _setLocalizedStatusMessage(
          skillId.isEmpty ? '技能安装完成。' : '已安装 $skillId。',
          skillId.isEmpty
              ? 'Finished installing the skill.'
              : 'Installed $skillId.',
        );
      },
    );
  }

  Future<void> rollbackSkillInstall({
    required String agent,
    required String snapshotId,
  }) async {
    await _runSkillHubAction(
      '正在回滚技能安装。',
      'Rolling back the skill installation.',
      () async {
        skillInstallResult = await agentService.rollbackSkillInstall(
          agent: agent,
          snapshotId: snapshotId,
        );
        skillHubActionResult = skillInstallResult;
        skillHubSkills = await agentService.listSkills(agent: agent);
        _setLocalizedStatusMessage(
          '已回滚技能安装快照 $snapshotId。',
          'Rolled back skill installation snapshot $snapshotId.',
        );
      },
    );
  }

  Future<void> _runSkillHubAction(
    String busyMessageChinese,
    String busyMessageEnglish,
    Future<void> Function() action,
  ) async {
    if (isSkillHubBusy) {
      return;
    }
    isSkillHubBusy = true;
    lastError = '';
    _setLocalizedStatusMessage(busyMessageChinese, busyMessageEnglish);
    statusCaption = 'Skill Hub';
    _notifyStateChanged();
    try {
      await action();
      statusCaption = 'Skill Hub';
    } catch (error) {
      debugPrint('Failed to run Skill Hub action: $error');
      lastError = error.toString();
      _setLocalizedStatusMessage(
        '技能中心操作失败。',
        'The Skill Hub operation failed.',
      );
      statusCaption = 'Skill Hub';
    } finally {
      isSkillHubBusy = false;
      _notifyStateChanged();
    }
  }
}
