class SkillVisualOverride {
  const SkillVisualOverride({this.iconId = '', this.colorToken = ''});

  final String iconId;
  final String colorToken;

  bool get isEmpty => iconId.trim().isEmpty && colorToken.trim().isEmpty;

  SkillVisualOverride copyWith({String? iconId, String? colorToken}) {
    return SkillVisualOverride(
      iconId: iconId ?? this.iconId,
      colorToken: colorToken ?? this.colorToken,
    );
  }

  factory SkillVisualOverride.fromJson(Map<String, dynamic> json) {
    return SkillVisualOverride(
      iconId: (json['iconId'] ?? '').toString().trim(),
      colorToken: (json['colorToken'] ?? '').toString().trim(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (iconId.trim().isNotEmpty) 'iconId': iconId.trim(),
      if (colorToken.trim().isNotEmpty) 'colorToken': colorToken.trim(),
    };
  }
}

class SkillHubPreferences {
  const SkillHubPreferences({this.overrides = const {}});

  static const currentSchemaVersion = 1;

  final Map<String, SkillVisualOverride> overrides;

  static SkillHubPreferences defaults() => const SkillHubPreferences();

  SkillVisualOverride overrideFor(String skillId) {
    return overrides[skillId.trim()] ?? const SkillVisualOverride();
  }

  SkillHubPreferences withOverride(
    String skillId,
    SkillVisualOverride override,
  ) {
    final key = skillId.trim();
    if (key.isEmpty) return this;
    final next = Map<String, SkillVisualOverride>.from(overrides);
    if (override.isEmpty) {
      next.remove(key);
    } else {
      next[key] = override;
    }
    return SkillHubPreferences(overrides: Map.unmodifiable(next));
  }

  factory SkillHubPreferences.fromJson(Map<String, dynamic> json) {
    final raw = json['overrides'];
    if (raw is! Map) {
      return SkillHubPreferences.defaults();
    }
    final overrides = <String, SkillVisualOverride>{};
    for (final entry in raw.entries) {
      final skillId = entry.key.toString().trim();
      if (skillId.isEmpty) continue;
      final value = entry.value;
      if (value is Map) {
        final parsed = SkillVisualOverride.fromJson(
          Map<String, dynamic>.from(value),
        );
        if (!parsed.isEmpty) {
          overrides[skillId] = parsed;
        }
      }
    }
    return SkillHubPreferences(overrides: Map.unmodifiable(overrides));
  }

  Map<String, dynamic> toJson() {
    final encoded = <String, dynamic>{};
    final keys = overrides.keys.toList()..sort();
    for (final key in keys) {
      final value = overrides[key];
      if (value == null || value.isEmpty) continue;
      encoded[key] = value.toJson();
    }
    return {'schemaVersion': currentSchemaVersion, 'overrides': encoded};
  }
}

abstract class SkillHubPreferencesStore {
  const SkillHubPreferencesStore();

  Future<Object?> read(Object portableData);
  Future<void> write(Object portableData, Object? payload);
}
