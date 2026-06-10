# Pathstitch — Implementation Checklist

Tracks every Linear issue, grouped by the implementation phases. Status reflects
work landed in the repo (verified by build + unit tests + logic review unless
noted). Last updated: 2026-06-09.

**Legend:** `[x]` done · `[~]` partial / in progress · `[ ]` not started
Priority: 🔴 Urgent · 🟠 High · 🟡 Medium · ⚪ None

---

## Phase 1 — Foundation: File System & Blank Canvas  ✅ complete

- [x] **MAS-21** 🔴 Completely overhaul file handling — empty-as-valid working buffer, robust routing, no more DXF-error fragility
- [x] **MAS-24** 🔴 File system — window = workspace, Save/Cancel/Discard prompt, `.stch` round-trips everything (incl. batch), `.stch` Finder icon
- [x] **MAS-14** 🔴 Save file project loading — `.stch` opens via Finder/menu/drag (added `application(_:open:)`)
- [x] **MAS-12** 🔴 Other format import — `.stch`/`.svg`/`.pdf` no longer error; routed correctly
- [x] **MAS-13** 🔴 Multiple file handling — fixed the `append_dxf` `Layer.name` crash; multi-file merge works
- [x] **MAS-8** 🔴 Deleting items — delete-to-empty works (empty SVG export no longer errors)
- [x] **MAS-49** 🟡 Blank Canvas — empty canvas is a first-class valid state
- [x] **MAS-9** 🟡 Clean Canvas Start — instant blank document, zero Python round-trips

---

## Phase 2 — Windowing: New Window Bugs & Startup  ⬜ not started

- [~] **MAS-37** 🟡 Blank Window on startup — likely improved by the new Finder-open handler; needs confirmation
- [~] **MAS-32** 🟠 Windowing (double windows on text / "open with") — open routing added; text-window bug remains
- [ ] **MAS-22** 🔴 Creating text creates a new window
- [ ] **MAS-39** 🟠 New File button → macOS menu bar
- [ ] **MAS-15** 🟡 "New Window" → rename to "New File"
- [ ] **MAS-41** 🟡 New Window Creation — offset position (cascade)

---

## Phase 3 — Performance: Loading Screens & Object Movement  ⬜ not started

- [ ] **MAS-25** 🔴 Performance (general overhaul)
- [~] **MAS-10** 🟠 Too many loading screens — blank/new no longer loads; broader pass pending
- [ ] **MAS-6** 🟠 Object movement lags behind cursor

---

## Phase 4 — Creation Tools: Text, Shapes, Images, Batch  ⬜ not started

- [~] **MAS-20** 🔴 Creation UI — DXF "no renderable geometry" error fixed; text-editing/parametric UX pending
- [ ] **MAS-23** 🔴 Image upload pipeline (reference image + Potrace tracing)
- [ ] **MAS-18** 🔴 Batch Item Preview (offsets / missing lines)

---

## Phase 5 — Canvas Interactions: Gizmos, Shortcuts, Ruler  ⬜ not started

- [ ] **MAS-27** 🟠 Gizmos & draggable arrows (scale / rotation / sizing / spacing)
- [ ] **MAS-38** 🟠 Draggable handles for Offset and Fillet
- [ ] **MAS-30** 🟠 Keyboard shortcuts (Photoshop-equivalent)
- [ ] **MAS-5** 🟡 Object rotation in gizmo
- [ ] **MAS-33** 🟡 Ruler deletion via Backspace

---

## Phase 6 — Geometry Operations  ⬜ not started

- [ ] **MAS-34** 🟠 Clean-up feature (snap gaps watertight)
- [ ] **MAS-35** 🟠 Hole Sewing ("both" side option + algorithm fixes)
- [ ] **MAS-29** 🟠 Paper Tab Generation (distance-from-ends + draggable arrows)
- [ ] **MAS-40** 🟠 DXF Quick Look (curves + isolated-point handling)

---

## Phase 7 — UI Architecture: Sidebar & Menu Bar Overhaul  ⬜ not started

- [ ] **MAS-44** 🔴 Left sidebar & tools spec (Photoshop-like layout)
- [ ] **MAS-47** 🟠 Update menu bar & sidebar tool organization
- [ ] **MAS-26** 🟠 Options panel (full non-collapsible right sidebar)
- [ ] **MAS-19** 🟠 Remove redundant bottom-4 file-control icons
- [ ] **MAS-16** 🟠 Learn toggle → menu bar only
- [ ] **MAS-45** ⚪ Extra tool-option toggles next to home button

---

## Phase 8 — Polish & UX: Icons, Hover, Tooltips, Errors  ⬜ not started

- [~] **MAS-48** 🟡 App Icon — icon assets added; sidebar-logo removal + dark/light wiring pending
- [ ] **MAS-11** 🟠 Right sidebar clicking (whole row clickable)
- [ ] **MAS-7** 🟡 Hovering bugs (sidebar color, object hover)
- [ ] **MAS-46** 🟡 Hover tooltips on clickable items
- [ ] **MAS-43** 🟡 Line details panel (bottom-right info)
- [~] **MAS-36** 🟡 De-erroring — several real errors fixed during Phase 1; dedicated stress-test pass pending

---

## Phase 9 — Advanced Feature: Layering  ⬜ not started

- [ ] **MAS-42** 🟡 Layering (Photoshop-like layers panel)

---

## Already completed before phased work

- [x] **MAS-28** 🟠 Origin position (locked on zoom) — marked Done in Linear
- [x] **MAS-17** 🔴 Chain selection — marked Done in Linear
- [x] **MAS-31** 🟡 App icon — closed as **Duplicate** of MAS-48

---

## Linear onboarding (not project work)

- [ ] **MAS-1** Get familiar with Linear
- [ ] **MAS-2** Set up your teams
- [ ] **MAS-3** Connect your tools
- [ ] **MAS-4** Import your data

---

## Summary

| Phase | Done | Partial | Not started | Total |
|---|---|---|---|---|
| 1 — File system & blank canvas | 8 | 0 | 0 | 8 |
| 2 — Windowing | 0 | 2 | 4 | 6 |
| 3 — Performance | 0 | 1 | 2 | 3 |
| 4 — Creation tools | 0 | 1 | 2 | 3 |
| 5 — Canvas interactions | 0 | 0 | 5 | 5 |
| 6 — Geometry operations | 0 | 0 | 4 | 4 |
| 7 — UI architecture | 0 | 0 | 6 | 6 |
| 8 — Polish & UX | 0 | 2 | 4 | 6 |
| 9 — Layering | 0 | 0 | 1 | 1 |
| Pre-completed | 2 (+1 dup) | — | — | 3 |

**Phase 1 of 9 complete.** Recommended next: Phase 2 (windowing) — several of its bugs are already partially addressed by the Phase 1 Finder-open handler.
