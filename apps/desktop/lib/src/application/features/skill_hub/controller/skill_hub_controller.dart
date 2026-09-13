import 'dart:async';

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
  List<Map<String, dynamic>> _localSkills = const [];
  final Map<String, List<Map<String, dynamic>>> _agentSkills = {};
  final Map<String, List<Map<String, dynamic>>> _agentPairings = {};

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
    bool retained(Map<String, dynamic> skill) =>
        (skill['path'] ?? '').toString() != normalizedPath;
    _localSkills = _localSkills.where(retained).toList(growable: false);
    _agentSkills.updateAll(
      (_, values) => values.where(retained).toList(growable: false),
    );
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
        _agentSkills.removeWhere((id, _) => !ids.contains(id));
        _agentPairings.removeWhere((id, _) => !ids.contains(id));
        final settled = Completer<void>();
        var pending = 1 + detected.length * 2;
        var selectedFailed = false;
        Object? localFailure;
        void completeSource() {
          pending--;
          if (pending == 0) settled.complete();
        }

        void publishSkills() {
          final catalog = SkillHubSkillCatalogBuilder(detectedAgentIds: ids);
          // Source order stays deterministic even when completion order changes.
          for (final skill in _localSkills) {
            catalog.addOrMergeSkill(skill, isPublic: skill['isPublic'] == true);
          }
          for (final id in ids) {
            for (final skill
                in _agentSkills[id] ?? const <Map<String, dynamic>>[]) {
              catalog.addOrMergeSkill(skill, agentId: id);
            }
          }
          catalog.ensureAgentAttribution();
          skills = List.unmodifiable(
            catalog.skills.map((skill) => Map<String, dynamic>.from(skill)),
          );
          publishChange();
        }

        unawaited(
          _localCatalogSource
              .scan(detectedAgentIds: ids)
              .then(
                (value) {
                  _localSkills = value;
                  publishSkills();
                },
                onError: (Object error) {
                  localFailure = error;
                },
              )
              .whenComplete(completeSource),
        );
        for (final target in detected) {
          final id = target.target;
          unawaited(
            _listPairingsIsolated(id)
                .then((result) {
                  selectedFailed =
                      selectedFailed || (result.failed && id == selectedAgent);
                  if (!result.failed) {
                    _agentPairings[id] = result.values;
                  }
                  pairings = List.unmodifiable([
                    for (final id in ids) ...?_agentPairings[id],
                  ]);
                  publishChange();
                })
                .whenComplete(completeSource),
          );
          unawaited(
            _listSkillsIsolated(id)
                .then((result) {
                  selectedFailed =
                      selectedFailed || (result.failed && id == selectedAgent);
                  if (!result.failed) _agentSkills[id] = result.values;
                  publishSkills();
                })
                .whenComplete(completeSource),
          );
        }
        // Publication happens in each source callback, including local scan.
        // Completion only releases the existing refresh workflow lock.
        await settled.future;
        if (selectedFailed || localFailure != null) {
          throw const _SelectedSkillHubAgentUnavailable();
        }
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

  Future<({List<Map<String, dynamic>> values, bool failed})>
  _listPairingsIsolated(String agentId) async {
    try {
      return (
        values: await _gateway.listPairings(agent: agentId),
        failed: false,
      );
    } catch (_) {
      return (values: const <Map<String, dynamic>>[], failed: true);
    }
  }

  Future<({List<Map<String, dynamic>> values, bool failed})>
  _listSkillsIsolated(String agentId) async {
    try {
      return (values: await _gateway.listSkills(agent: agentId), failed: false);
    } catch (_) {
      return (values: const <Map<String, dynamic>>[], failed: true);
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
