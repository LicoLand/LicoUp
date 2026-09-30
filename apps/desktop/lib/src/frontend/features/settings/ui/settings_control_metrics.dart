/// Shared control geometry for settings surfaces: every selection control
/// (dropdown, segmented control) renders at the same height and width, and
/// settings action buttons use the same height, so rows in one section line
/// up with rows in every other section.
///
/// A component nested inside a framed control keeps one margin on every side
/// that faces the frame interior — a trailing inset matches top, bottom and
/// right; a leading inset matches top, bottom and left; a corner inset
/// matches its two adjacent sides — using `LicoContentSpacing.inline`. Fills
/// for such nested components come from the neutral elevation steps (for
/// example `surfaceSunken`), never from brand tints.
const double settingsControlHeight = 36;
const double settingsControlWidth = 320;
