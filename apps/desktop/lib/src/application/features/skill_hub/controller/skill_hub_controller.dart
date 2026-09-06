import 'package:licoup/src/application/state/application_signal.dart';

import 'package:licoup/src/application/features/skill_hub/controller/skill_hub_status.dart';
import 'package:licoup/src/application/features/skill_hub/services/skill_hub_skill_catalog.dart';
import 'package:licoup/src/contracts/skill_hub.dart';
import 'package:licoup/src/contracts/skill_hub_preferences.dart';
import 'package:licoup/src/contracts/target_candidate.dart';

/// Owns the local Skill Hub catalog, pairing, and visual preferences.
class SkillHubController extends ApplicationStateOwner {
  SkillHubController({
    required SkillHubGateway gateway,
    required SkillHubPreferencesRepository preferencesRepository,
    required SkillHubLocalCatalogSource localCatalogSource,
    required Object portableData,
    required List<TargetCandidate> Function() targets,
    required Future<void> Function() ensureTargets,
    required SkillHubStatusSink onStatus,
    DateTime Function()? now,
  }) : _gateway = gateway,
       _preferencesRepository = preferencesRepository,
       _localCatalogSource = localCatalogSource,
       _portableData = portableData,
       _targets = targets,
       _ensureTargets = ensureTargets,
       _onStatus = onStatus,
       _now = now ?? DateTime.now;

  /// How long a successful [refresh] result is reused before the next
  /// non-forced refresh scans again. Lets background-preloaded data serve
  /// panel entries instantly.
  static const Duration refreshFreshnessWindow = Duration(minutes: 5);

  final SkillHubGateway _gateway;
  final SkillHubPreferencesRepository _preferencesRepository;
  final SkillHubLocalCatalogSource _localCatalogSource;
  final Object _portableData;
  final List<TargetCandidate> Function() _targets;
  final Future<void> Function() _ensureTargets;
  final SkillHubStatusSink _onStatus;
  final DateTime Function() _now;

  DateTime? _lastRefreshedAt;

  List<Map<String, dynamic>> pairings = const [];
  List<Map<String, dynamic>> skills = const [];
  SkillHubPreferences preferences = SkillHubPreferences.defaults();
  Map<String, dynamic>? actionResult;
  bool busy = false;
  String lastErrorCode = '';

  void replacePairings(List<Map<String, dynamic>> value) {
    pairings = List.unmodifiable(value);
    publishChange();
  }

  void replaceSkills(List<Map<String, dynamic>> value) {
    skills = List.unmodifiable(value);
    publishChange();
  }

  void removeSkillAtPath(String path) {
    final normalizedPath = path.trim();
    if (normalizedPath.isEmpty) return;
    final remaining = skills
        .where((skill) => (skill['path'] ?? '').toString() != normalizedPath)
        .toList(growable: false);
    if (remaining.length == skills.length) return;
    skills = List.unmodifiable(remaining);
    publishChange();
  }

  void replacePreferences(SkillHubPreferences value) {
    preferences = value;
    publishChange();
  }

  void replaceActionResult(Map<String, dynamic>? value) {
    actionResult = value;
    publishChange();
  }

  void replaceBusy(bool value) {
    busy = value;
    publishChange();
  }

  Future<void> loadPreferences() async {
    preferences = await _preferencesRepository.load(_portableData);
    publishChange();
  }

  Future<void> refresh(
    String selectedAgent, {
    bool forceRefresh = false,
    bool showProgress = true,
  }) async {
    if (!forceRefresh && _hasFreshCatalog) return;
    await _run(
      busyChinese: '正在扫描所有智能体的技能。',
      busyEnglish: 'Scanning skills loadable by local agents.',
      showProgress: showProgress,
      action: () async {
        var candidates = _targets();
        if (candidates.isEmpty) {
          await _ensureTargets();
          candidates = _targets();
        }
        final detected = candidates
            .where((target) => target.status != 'not-detected')
            .toList(growable: false);
        final ids = detected
            .map((target) => target.target)
            .toList(growable: false);
        final catalog = SkillHubSkillCatalogBuilder(detectedAgentIds: ids);

        final localSkillsFuture = _localCatalogSource.scan(
          detectedAgentIds: ids,
        );
        final pairingFutures = [
          for (final target in detected)
            _listPairingsIsolated(target.target, selectedAgent),
        ];
        final skillFutures = [
          for (final target in detected)
            _listSkillsIsolated(target.target, selectedAgent),
        ];
        final localSkills = await localSkillsFuture;
        for (final skill in localSkills) {
          catalog.addOrMergeSkill(skill, isPublic: skill['isPublic'] == true);
        }
        final pairingResults = await Future.wait(pairingFutures);
        final skillResults = await Future.wait(skillFutures);
        if (pairingResults.any((result) => result.selectedFailed) ||
            skillResults.any((result) => result.selectedFailed)) {
          throw const _SelectedSkillHubAgentUnavailable();
        }
        final allPairings = <Map<String, dynamic>>[
          for (final result in pairingResults) ...result.values,
        ];
        for (var index = 0; index < skillResults.length; index += 1) {
          final agentId = detected[index].target;
          for (final skill in skillResults[index].values) {
            catalog.addOrMergeSkill(skill, agentId: agentId);
          }
        }
        catalog.ensureAgentAttribution();
        pairings = List.unmodifiable(allPairings);
        skills = List.unmodifiable(
          catalog.skills.map((skill) => Map<String, dynamic>.from(skill)),
        );
        actionResult = {
          'ok': true,
          'agent': selectedAgent,
          'pairings': pairings.length,
          'skills': skills.length,
        };
        if (showProgress) {
          _onStatus(
            SkillHubStatusUpdate(
              chinese: '已扫描本机所有智能体的技能（共 ${skills.length} 个技能）。',
              english:
                  'Scanned ${skills.length} skills loadable by local agents.',
            ),
          );
        }
        _lastRefreshedAt = _now();
      },
    );
  }

  bool get _hasFreshCatalog =>
      skills.isNotEmpty &&
      _lastRefreshedAt != null &&
      _now().difference(_lastRefreshedAt!) < refreshFreshnessWindow;

  Future<({List<Map<String, dynamic>> values, bool selectedFailed})>
  _listPairingsIsolated(String agentId, String selectedAgent) async {
    try {
      return (
        values: await _gateway.listPairings(agent: agentId),
        selectedFailed: false,
      );
    } catch (_) {
      return (
        values: const <Map<String, dynamic>>[],
        selectedFailed: agentId == selectedAgent,
      );
    }
  }

  Future<({List<Map<String, dynamic>> values, bool selectedFailed})>
  _listSkillsIsolated(String agentId, String selectedAgent) async {
    try {
      return (
        values: await _gateway.listSkills(agent: agentId),
        selectedFailed: false,
      );
    } catch (_) {
      return (
        values: const <Map<String, dynamic>>[],
        selectedFailed: agentId == selectedAgent,
      );
    }
  }

  Future<void> requestPairing(String agent, {String target = ''}) async {
    await _run(
      busyChinese: '正在请求技能中心配对。',
      busyEnglish: 'Requesting Skill Hub pairing.',
      action: () async {
        actionResult = await _gateway.requestPairing(
          agent: agent,
          target: target,
        );
        pairings = List.unmodifiable(await _gateway.listPairings(agent: agent));
        _onStatus(
          SkillHubStatusUpdate(
            chinese: '已请求 $agent 配对。',
            english: 'Requested pairing for $agent.',
          ),
        );
      },
    );
  }

  Future<void> approvePairing(String agent) async {
    await _run(
      busyChinese: '正在批准技能中心配对。',
      busyEnglish: 'Approving Skill Hub pairing.',
      action: () async {
        actionResult = await _gateway.approvePairing(agent: agent);
        pairings = List.unmodifiable(await _gateway.listPairings(agent: agent));
        skills = List.unmodifiable(await _gateway.listSkills(agent: agent));
        _onStatus(
          SkillHubStatusUpdate(
            chinese: '已批准 $agent 配对。',
            english: 'Approved pairing for $agent.',
          ),
        );
      },
    );
  }

  Future<void> revokePairing(String agent) async {
    await _run(
      busyChinese: '正在撤销技能中心配对。',
      busyEnglish: 'Revoking Skill Hub pairing.',
      action: () async {
        actionResult = await _gateway.revokePairing(agent: agent);
        pairings = List.unmodifiable(await _gateway.listPairings(agent: agent));
        skills = const [];
        _onStatus(
          SkillHubStatusUpdate(
            chinese: '已撤销 $agent 配对。',
            english: 'Revoked pairing for $agent.',
          ),
        );
      },
    );
  }

  Future<void> updateVisualOverride({
    required String skillId,
    String? iconId,
    String? colorToken,
  }) async {
    final id = skillId.trim();
    if (id.isEmpty) return;
    final current = preferences.overrideFor(id);
    final next = SkillVisualOverride(
      iconId: (iconId ?? current.iconId).trim(),
      colorToken: (colorToken ?? current.colorToken).trim(),
    );
    preferences = preferences.withOverride(id, next);
    publishChange();
    try {
      await _preferencesRepository.save(_portableData, preferences);
    } catch (_) {
      lastErrorCode = 'skill_hub_preferences_save_failed';
      _onStatus(
        const SkillHubStatusUpdate(
          chinese: '技能显示偏好保存失败。',
          english: 'Failed to save Skill Hub display preferences.',
          errorCode: 'skill_hub_preferences_save_failed',
        ),
      );
      publishChange();
    }
  }

  Future<void> _run({
    required String busyChinese,
    required String busyEnglish,
    required Future<void> Function() action,
    bool showProgress = true,
  }) async {
    if (busy) return;
    busy = true;
    lastErrorCode = '';
    if (showProgress) {
      _onStatus(
        SkillHubStatusUpdate(chinese: busyChinese, english: busyEnglish),
      );
    }
    publishChange();
    try {
      await action();
    } catch (_) {
      lastErrorCode = 'skill_hub_operation_failed';
      if (showProgress) {
        _onStatus(
          const SkillHubStatusUpdate(
            chinese: '技能中心操作失败。',
            english: 'The Skill Hub operation failed.',
            errorCode: 'skill_hub_operation_failed',
          ),
        );
      }
    } finally {
      busy = false;
      publishChange();
    }
  }
}

class _SelectedSkillHubAgentUnavailable implements Exception {
  const _SelectedSkillHubAgentUnavailable();
}
