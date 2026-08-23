# shell/ — Application Shell

Migration target for app-level layout, navigation, and window chrome.
The shell is the outermost widget layer that composes features into the final UI.

## Subdirectories

| Directory | Purpose | Migration Source |
|:---|:---|:---|
| `layout/` | Layout system, surfaces, responsive breakpoints | `frontend/layout/` |
| `navigation/` | Destination routing, deep linking | `frontend/shell/`, `application/features/navigation/` |
| `chrome/` | Window chrome, title bar, platform-specific decorations | `platform/window_chrome/` |

## Rules

- Shell widgets import feature `presentation/` widgets but never their `application/`
- Navigation state is a Riverpod provider, not a mixin on the god controller
- Layout decisions are pure functions of window size + user preference
