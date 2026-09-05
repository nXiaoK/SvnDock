# SvnDock desktop design

The user's September 2026 reference images define the visual direction for the
native macOS application. They take precedence over the workspace's marketing
design defaults.

- Use a cool, pale blue sidebar, white content surfaces, navy text, and a vivid
  blue accent (`#2B66FF`). Support dark appearance with the same semantic roles.
- Keep a single app command bar, a working-copy summary, and clear resizable
  repository / file / inspector columns. Keep native window controls.
- Use 8–12 pt corner radii, quiet 1 pt borders, and blue selection fills. Avoid
  decorative shadows inside document panes.
- Use the system font: 20 pt section titles, 14–16 pt file titles, 12–13 pt body
  and metadata. Use a 12 pt monospaced font for code with aligned line numbers.
- Space related elements by 4–8 pt, controls by 12 pt, and sections by 16–24 pt.
- Show file types with simple SF Symbols in softly tinted icon tiles. Status
  pills retain text labels; green/red are reserved for additions/removals and
  conflict status.
- Commit uses a spacious sheet with a message, explicit file selection, and a
  real file diff preview. Keep primary actions at the lower right.
- Commit diff can expand into a focused reading layout within the same sheet.
  Preserve the draft, file inclusion, diff mode and text size. Escape returns
  to the commit form. Offer file navigation and 10–20 pt diff text sizing.
- The complete visible button bounds must respond, including padding and
  space between icons and labels. Put hit shapes after label layout, keep
  decorative overlays noninteractive, and show hover/pressed/disabled states.
- Match reference styling without inventing repository data, authors, line
  counts, recent projects, AI services, or unsupported merge functionality.
- Preserve keyboard navigation, multi-selection, resize behavior, accessible
  labels, operation disabled states, and destructive-action confirmations.

Shared implementation tokens and controls live in `StatusVisuals.swift`.
