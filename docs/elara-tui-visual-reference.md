# Approved Elara TUI visual references

Recorded 2026-09-04. This document preserves design provenance; requirements and
execution status live only in [ROADMAP.md](../ROADMAP.md).

## Approved directions

| Layout | Structure | Original palette |
| --- | --- | --- |
| Ember | Single-column conversation with inline thinking | Charcoal and amber |
| Observatory | Conversation beside a thinking pane | Blue-black and teal |
| Workbench | Turn navigation with a thinking strip | Violet and lavender |

All three layouts and palettes were approved. Layout and theme must become
independent choices, switchable before or during a session. Forest is a fourth
palette: the near-black green background and sage text of the owner's Amp
screenshot. It is approved as a direction but is not in the original HTML study.
Thinking is visible and expanded by default and remains open until hidden by
the user. The mockups do not establish provider capabilities or terminal behavior.

## Exact local archive

- Branch: `codex/elara-tui-design-studies`
- Commit: `fcf163ced9b3af2e1b1fb8a3b2745ca7cb0cc3f6`
- Directory: `docs/design/prototype-reference/`
- Interactive study: `elara-tui-prototypes.html`, copied byte-for-byte from the
  approved conversation artifact.
- Original reference screenshots: `grok-home.png`, `grok-streaming.png`,
  `grok-completed.png`, `grok-thinking.png`, `amp-forest-reference.png`.
- Local checkout: `/tmp/elara-tui-design-studies` (convenience only; the committed
  branch is the durable reference).

Recover the study from the repository without the temporary checkout:

```sh
git show fcf163ced9b3af2e1b1fb8a3b2745ca7cb0cc3f6:docs/design/prototype-reference/elara-tui-prototypes.html > /tmp/elara-tui-prototypes.html
```

The archive is committed locally and has not been pushed. Screenshots include
personal workspace details and must not be published as public project assets.
Share sanitized design references separately if implementation moves to another
machine. Keeping the prototype on its own branch avoids shipping mock behavior.

## Implementation comparison

TUI-7 must define exact semantic tokens and capture actual Ghostty/WezTerm frames
for all twelve combinations. Compare hierarchy, spacing, thinking readability,
focus, tool expansion, and narrow-window behavior against these references.
Browser prototype approval is visual evidence only; no terminal implementation
or interaction acceptance is implied. Original palettes are starting points,
not a requirement to reproduce low-contrast text or browser-only geometry.

The terminal implementation defines its concrete tokens in
[`appearance.rs`](../native/elara-tui/src/appearance.rs). Automated
[reference frames](../native/elara-tui/tests/goldens/appearance/) cover every
layout/theme pair at 80×24, 120×40, and 180×45 for idle, composing, streaming,
reasoning shown/hidden, and failed-tool states. They record terminal cell text;
Rust tests separately check token contrast and state preservation. These frames
are not screenshots or evidence of physical keyboard/mouse acceptance.
