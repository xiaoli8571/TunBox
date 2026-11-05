# Desktop Card, Quick Launch, and Light Theme Fixes

## Changes

- Reworked the 2x2 toggle card into a compact status row, node row, and full-width action button. Reduced the outer inset and button height so the button fits within short phone launcher cells.
- Mirrored the home page's optimistic connection state into the quick launch button before any asynchronous preparation. The icon stays green while the real connection starts, and returns to the brand color after failure or cancellation. Confirmed connection remains green; disconnecting remains orange.
- Added four revision-aware semantic palettes for primary, secondary, muted, and brand colors. Mint, Homebrew, and Noctis each receive a distinct brand hue; the default and dark palettes retain their existing colors.
- Renamed the setting to "Backup and restore" / "备份与恢复", removed the settings privacy-policy entry and its AppGallery link lookup, and updated the light-background note.

## Verification

- `node scripts/verify-remediation-types.mjs`: passed (0 repository type diagnostics; ArkUI pairing check passed).
- `scripts/verify-shortcut-lifecycle.ps1`: passed.
- `node scripts/verify-startup-feedback-runtime.mjs`: 15 cases passed, including immediate green quick launch state and rollback.
- `node scripts/verify-theme-palette-runtime.mjs`: all four light palettes meet 4.5:1 text contrast; dark palette remains independent.
- Settings string JSON parses; no privacy-policy references remain in the settings page/resources.

The CodeGenie MCP build tools required by the HarmonyOS build skill are unavailable in this session, so no clean HAP build or device install was performed. The attached phone was screen-off during read-only inspection; widget layout was not visually rechecked on-device.
