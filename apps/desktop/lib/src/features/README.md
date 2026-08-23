# features/ — Vertical Feature Slices

Migration target for the feature-first architecture.
Each feature is a self-contained vertical slice with three internal layers.

## Structure per Feature

```
feature_name/
├── domain/        # Feature-local contracts, models, abstract repositories
├── application/   # Feature controller (Riverpod providers, notifiers)
└── presentation/  # Widgets, pages, components
```

## Rules

- Features MUST NOT import from other features' `application/` or `presentation/`
- Cross-feature communication goes through `core/` shared models or Riverpod providers
- Each feature has exactly ONE Riverpod provider family as its public API
- `domain/` contains only abstract definitions and data classes
- `application/` contains Riverpod AsyncNotifiers/Notifiers (one per concern)
- `presentation/` contains only widgets; no business logic

## Features Index

| Feature | Responsibility | Migration Source |
|:---|:---|:---|
| `conversation/` | Agent conversation lifecycle, messages, turns, streaming | `application/features/agents/conversation/`, `frontend/features/agents/ui/` |
| `agent_hub/` | Agent discovery, installation, management | `application/features/agent_hub/`, `frontend/features/agent_hub/` |
| `settings/` | App settings, updates, directories | `application/features/settings/`, `frontend/features/settings/` |
| `skill_hub/` | Skill management and preferences | `application/features/skill_hub/`, `frontend/features/skill_hub/` |
| `mobile_relay/` | Mobile relay and secure mesh | `application/features/mobile_relay/`, `frontend/features/mobile_relay/` |
| `models_management/` | LLM model/provider configuration | `application/features/models/`, `frontend/features/models/` |
| `plugin_management/` | Optional collaboration plugins | `application/features/plugin_management/`, `frontend/features/plugin_management/` |
| `targets/` | Local agent target scanning and management | `application/features/targets/`, `frontend/features/targets/` |
