# shared/ — Cross-Feature Shared UI

Migration target for reusable widgets, theme definitions, and localization.

## Subdirectories

| Directory | Purpose | Migration Source |
|:---|:---|:---|
| `widgets/` | Reusable UI components (buttons, cards, indicators) | `frontend/shared/` |
| `theme/` | Theme data, color schemes, typography | `frontend/shared/ui/theme.dart`, `frontend/shared/appearance/` |
| `l10n/` | Localization strings and delegates | `frontend/l10n/` |

## Rules

- No business logic
- No feature-specific imports
- All widgets here must be usable by any feature
