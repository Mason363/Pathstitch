# Pathstitch — Open Issues (not started)

Snapshot from Linear as of 2026-06-16. Includes every `MAS-` issue in **Todo** or **Backlog** status
(i.e. not yet started) under the Pathstitch project. Excludes the 4 default Linear onboarding issues
(`MAS-1`–`MAS-4`, "Get familiar with Linear" etc.) since they aren't real project work, and excludes
anything already In Progress / In Review / Done.

Groups are ordered so that foundational/blocking work comes first and things that depend on it come
later. Within a group, issues are reproduced word-for-word from Linear (trimmed only of redundant
boilerplate, e.g. repeated acceptance-criteria checklists that just restate the spec above them).

---

## Best practices for this codebase

- **Architecture.** Swift/SwiftUI frontend talks to a single persistent Python worker
  (`python -m pathstitch_core.worker`) over length-prefixed JSON frames on stdin/stdout
  (`PythonBridge.swift`). Never spawn a fresh Python process per operation — that was the old,
  slow design.
- **Test geometry changes in Python first.** Before considering any `pathstitch_core/dxf_ops.py`
  change done, run `PYTHONPATH=. python pathstitch_core/test_dxf_ops.py` and confirm
  `ALL TESTS PASSED SUCCESSFULLY!`.
- **Build command.** `xcodebuild -project Pathstitch.xcodeproj -scheme Pathstitch -configuration Debug build`
  from the `Pathstitch/Pathstitch` subdirectory.
- **Interactive tool session pattern (Enter confirms / Esc cancels).** Fillet/Chamfer establish a
  pattern worth reusing for any new interactive/parametric tool (Offset, Patterning, Mirror, Image
  transform, etc. — see MAS-111): on tool entry, capture the undo-stack depth; on Enter or tool exit,
  commit; on Esc, restore `undoStack[depth]` and truncate. Don't invent a new commit/cancel mechanism
  per tool.
- **Undo/redo round-trips matter.** `HistoryState` must carry `parametricShapes` and
  `cornerSnapPoints`, or parametric shapes desync after undo. Any new tool that adds persistent
  per-entity state needs to extend `HistoryState` the same way, not bolt on a side channel.
- **Dirty-flag discipline.** `hasUnsavedChanges = true` is set centrally inside `saveToHistory()`.
  Any new geometry-mutating code path should funnel through `saveToHistory()` rather than setting the
  flag ad hoc — that's how a previous "edits don't mark the doc dirty" bug happened.
- **Toolbar additions go through the registry.** `ToolbarLayout.swift` / `ToolbarItemViews.swift` own
  the persisted, drag-reorderable toolbar. New tools belong in `ToolbarRegistry`, not hardcoded into
  `ContentView`.
- **Theming.** `ThemeManager.apply` is called on launch and on Preferences `onChange`, and propagates
  via `NSApp.appearance`. Any new window type must call it too or it'll ignore the user's theme.
- **computer-use can't deliver a working Escape key** to this app (a harness limitation, not an app
  bug). Don't trust computer-use to verify Esc-driven behavior — review the code path or test by hand.
- **Never add `Co-Authored-By: Claude` trailers** to commits in this repo — the user wants the repo to
  read as solely their own work, and history has already been scrubbed + force-pushed once for this.
- **Packaging.** `scripts/package_app.sh` bundles a trimmed conda env + `pathstitch_core` into
  `Contents/Resources`, ad-hoc signs (hardened runtime OFF so the conda libs' ad-hoc signatures aren't
  rejected). Re-run it after any Python dependency change rather than hand-editing `dist/`.

---

## 1. App / window lifecycle
*Foundational — other groups assume windows, files, and workspaces behave correctly.*

- [x] **Group 1 done** — implemented 2026-06-16; builds clean; marked In Progress in Linear for review.

### MAS-138 — Closing
> When the starting window is closed, the app is still 'open', but no windows show up. When the starting window is closed and it's the last window, make the app just quit.

### MAS-104 — New file
> New file (in menu bar) -> new window (doesn't delete the original window)

### MAS-107 — 3D and 2D go in the SAME WORKSPACE and SAME WINDOW
> As per title. There is currently this bug where importing a 3D model creates a new window. Remeber:
> 3D and 2D share the same workspace, same window, same .stch file, everything. Only batch mode creates a new window.

### MAS-139 — Recent projects in the starting screen
> Have a three dot menu for them, on the top right corner of the little preview (thumbnail) for each recent project, and have two options: reveal in finder and remove from recent projects.
>
> The two options do what they sound like.

---

## 2. Selection & gizmo conflicts
*Core interaction — until clicking/selecting is reliable, every other tool is harder to test and use.*

- [x] **Group 2 done** — implemented 2026-06-16; builds clean; marked In Progress in Linear for review.

### MAS-116 — Selection
> Clicking a line/geometry should also be a way of selecting, but oddly enough, in some places, it doesn't work. Also, selection in most places just feel… off. Fix that.

### MAS-101 — Move/rotate gizmo overlaps the Fillet/Chamfer tool controls
> Found during agent UI testing.
>
> When a shape is selected and you then activate the **Fillet** (or **Chamfer**) tool, the translate/rotate gizmo — center square + red X-axis arrow + green/blue rotate handle — keeps rendering on top of the shape, on top of the corner-editing UI. The red move-arrow sits right next to the fillet's inward radius arrow and the per-corner handles, so it both clutters the view and invites mis-grabs (grabbing/moving the shape when you meant to drag the fillet radius).
>
> **Suggested:** hide the translate/rotate gizmo while a corner tool (Fillet/Chamfer) is active, leaving only the corner handles and the active-corner radius arrow. (Verified the fillet itself works — this is purely the overlapping gizmo.)

### MAS-127 — Point to point movement
> Point to point movement is not exact. Make it exact.

---

## 3. Core sketch-editing tool bugs
*These tools are advertised as working but reportedly are not — fix before building features on top of them.*

- [x] **Group 3 done** — implemented 2026-06-16; builds clean; Python tests pass; marked In Progress in Linear for review. (MAS-109 associative dimension constraint deferred to the Group 5 dimension system; everything else done.)

### MAS-109 — Offset is still extremely buggy
> Fix offset, make it work like how it should:
>
> **1. Tool Activation & Selection Mode**
> - **Trigger:** Click the **Offset** tool icon in the left hand toolbar or press the hotkey.
> - **Selection Behavior:** The cursor changes to an offset-specific pointer. Hovering over sketch entities highlights them in a pre-selection color. Left-clicking the geometry selects it. If geometry is selected before the tool is triggered, that geometry is loaded as the selection.
> - **Chain Selection Toggle:** have chain selection be default -> on when it is triggered with no already loaded selection.
>
> **2. The Interactive Offset State**
> - **Immediate Preview:** The moment geometry is selected, a ghosted, dynamic preview line appears parallel to the original lines at a default distance (e.g., 1.0 mm).
> - **The Gizmo (Dimension Arrow):** A single, double-ended arrow handle appears perpendicular to the selected geometry. Dragging this handle moves the preview lines closer to or further from the source geometry.
>
> **3. Numerical Input & Dimensioning**
> - **Floating Input Box:** A persistent text input box floats directly next to the cursor/arrow handle during the drag action, displaying the current offset distance.
> - **Precise Entry:** Typing a number immediately focuses this box. Pressing `ENTER` commits that exact distance.
> - **Persistent Dimension:** Once committed, a standard sketch dimension constraint is automatically created between the original geometry and the offset geometry, allowing the user to double-click and change the offset distance later.
> - It is possible for users to click on the offset line with the offset tool and offset it again.
>
> **4. Right-Hand Active Tool Options Panel**
> - **Distance Field:** A numeric input box mirroring the floating cursor dimension.
> - **Flip Direction Button:** Inverts the positive/negative calculation of the offset distance.
> - **Geometry Type Toggle:** *Normal (Default):* Creates standard, solid sketch lines that can form profiles for extrusion. *Construction:* Creates dashed construction lines instead.
> - **Execution Actions:** **"OK"** button to commit the offset and exit the tool, or **"Cancel"** (`ESC`) to drop the tool without generating geometry.

### MAS-115 — Convert line
> It doesn't work, like at all

### MAS-130 — Apply join/cleanup
> Apply join/cleanup just doesn't work. It, right now, just removes the line that should have been fixed. This is how it should work:
>
> Identify points that should be inside the tolerance distance to each other
>
> Draw a line from point A's hanging endpoint to point B's hanging endpoint. A straight line. That's all. Do it on all broken endpoints.
>
> That's all. The lines are on the same layer. Fix it.

### MAS-103 — Fillets v3
> Fillets that are selected together have the same fillet radius (not linked, just that if the user selects each corner of a rectangle together without selecting off the tool in any way, then the three fillets are the same radius)

---

## 4. Toolbar & active-tool-panel UI
*Visual/interaction layer for tools — best done once the underlying tool set (groups 2–3) is stable.*

- [x] **Group 4 done** — implemented 2026-06-16; builds clean; marked In Progress in Linear for review. (MAS-121: handle-less one-shot tools left as-is; patterning/mirror gizmos are their own Group 7 issues.)

### MAS-117 — Tool bar organization
> Our current side toolbar has become unorganized as new features have been added. Tools are sitting in a continuous vertical stack without logical grouping, consistent bounding box padding, or a unified active state design language.
>
> We need to group the tools into functional zones using visual dividers, standardize the icon bounding boxes, and implement nested flyout menus for secondary operations to reduce visual noise and improve canvas scannability.
>
> **Proposed Toolbar Architecture**
>
> | Group | Tools Included | UI Treatment |
> |---|---|---|
> | 0. Global Selection | Select, Move, Pan | Top block. Uses a unified, subtle background tint for the active state. |
> | 1. Modifications | Offset, Holes (Sewing), Line Clean-up, Trim | Grouped with a thin horizontal divider line underneath. |
> | 2. Annotation & Precision | Measuring (Ruler), Fillet, Chamfer | Dedicated precision group. |
> | 3. Creation & Output | Shapes (Nested), Patterning, Paper Tool(s) | Patterning and Shapes should sit together. |
> | 4. Utilities (Flyout Menu) | Mirror, Convert Line, Flip H, Flip V, Duplicate | Collapsed under a single `...` (Other Tools) menu. |
>
> *Note: The duplicate "Offset tool" in the current list should be consolidated into a single instance.*
>
> **Implementation Requirements**
> - **Icon Standardization:** Enforce an identical, square bounding box size (e.g., 44×44 px) for every tool slot.
> - **Unified Active State:** Eliminate the mix of border outlines and background tints. Standardize on a subtle background tint when a tool is active.
> - **Nested Menus (Flyouts):** The **Shapes** tool should act as a single slot with a small chevron indicator that expands to reveal specific geometric primitives. The **Other Tools** (`...`) slot must open an anchor popover containing the utilities list.

### MAS-114 — Active tool option improvements
> Active tool options are uncollapsable and not in their own sub-boundary. They are filling the active tool option top panel, and they are uncollapsable.

### MAS-102 — Trim verbose instructional text in tool option panels (reads like a manual)
> Part of the "make it feel like good software" pass — flagging UI copy that's more how-to-manual than interface.
>
> A few tool option panels carry full instructional sentences explaining mechanics the user discovers instantly by doing:
> - **Rectangle Sketch** panel: *"Click and drag corner-to-corner. Corners are filleted using the radius specified above."*
> - **Fillet** panel: *"4 corners — each is individual. Drag the corner arrow or edit the active corner's value."*
>
> **Suggested:** trim to a short hint or drop entirely. e.g. Rectangle panel keeps just the "Fillet Radius (mm)" field; Fillet panel shortens to something like "Per-corner radius" or nothing. Keep labels, lose the sentences.
>
> (Title says "Trim" the text — not related to the Trim tool.)

### MAS-131 — More windowing options
> Add more windowing options, which include dragging to resize (change the width of) the right hand side panels (things within scale to fit, text never gets larger but the spacing changes) and the left hand side bar (the tools automatically adjust to fit the more space (can't go less, default is the least it could go) by adding more columns (having for example 2x9 not 1x18)

### MAS-121 — Tool fluidity improvement
> You've likely noticed a big part of new features have draggable and interactive handles. I want you to make that a standard across every tool that should have draggable and interactive handles to make it a standard and to make them all interactive and make them all feel nice. Now a lot of other tools already implemented have good draggable interactive handles. I want you to focus on the tools that currently do not.

---

## 5. Dimensioning & precision input system
*Used by many other tools (offset, transform, sketch primitives) — settle the core behavior before relying on it elsewhere.*

- [x] **Group 5 done** — implemented 2026-06-17; builds clean; marked In Progress in Linear for review. New Dimension tool (D) + parameter engine (formulas/units/vars/fx/cycles/driven). Bounded deferrals noted in the MAS-110 Linear comment (angular dims, scale-on-first-dim, auto over-constraint dialog, full associative geometry re-drive).

### MAS-110 — Dimentions
> **1. Tool Activation & Context-Aware Selection (`D` Hotkey)**
> - **Smart Selection Logic:** The tool automatically determines the dimension type based on the selected entities: *Single Line:* Linear length. *Two Parallel Lines:* Distance between them. *Two Non-Parallel Lines:* Angular dimension. *Circle/Arc:* Diameter or Radius. *Two Points:* Linear or aligned distance between nodes.
> - **The "Strict Input" Rule (Automatic Dimension Generation):** *Implicit Creation (No Initial Dimension):* If a user draws a rectangle (or line) by dragging and clicking without typing numbers, it receives no visible dimension constraints — remains blue (unconstrained) and free to drag. *Explicit Creation (Automatic Dimension):* If the user types a value into the floating input boxes while drawing and hits `ENTER`, the app automatically generates and places persistent dimension lines.
>
> **2. Dimension Anatomy (Signals & Lines)**
> - **Extension Lines:** Thin, solid lines projecting perpendicularly from the sketch geometry, with a small fixed gap (1–2 mm) so they never blend into the sketch lines.
> - **Dimension Line:** Run perpendicular to the extension lines, terminated with solid arrowheads.
> - **Text Placement:** The parameter value sits centered on or breaking the dimension line.
> - **State Colors:** *Active/Normal:* Black/dark gray (or a suitable non-blending color). *Driven/Reference:* Enclosed in parentheses — e.g. `(50 mm)` — signaling it's calculated by other geometry and can't be directly edited.
>
> **3. Parameter Engine & Formula References**
> - **Automatic Variable Assignment:** Every dimension gets a unique sequential variable name (`d1`, `d2`, `d3`).
> - **Formula Parsing:** Direct math (`20 * 2`), variable reference (`d1`), mixed expressions (`(d1 * 0.5) + 10`, `sqrt(d2^2 + d3^2)`).
> - **The "fx:" Prefix:** Once a formula is committed, the canvas text shows `fx: [Evaluated Value]`; hovering reveals the raw equation.
>
> **4. Niche Edge Cases & Critical Missing Details**
> - **Circular Dependency Trap:** If `d2` references `d1` and the user tries to make `d1` reference `d2`, block the input with a red highlight and "Circular dependency detected".
> - **Over-Constraint (Driven Dimensions):** If a new dimension would over-constrain an already-fully-constrained sketch, show a dialog offering to create a Driven Dimension `(d4)` instead.
> - **Scale on First Dimension:** Adding the very first strict numerical dimension to a completely un-dimensioned sketch should scale the entire sketch proportionally, not mangle the geometry.
> - **Unit Mix-and-Match:** The parser must handle mixed unit entries natively (e.g. typing `1 inch` or `2.54 cm` in a mm-default workspace converts to `25.4` internally while preserving the typed text).

### MAS-111 — Dimension Field v2
> **Global Dimension Field Behavior (`ENTER` Key)**
> - **Universal Confirmation:** Pressing `ENTER` inside any numeric input field — Offset distance, a Transform gizmo (move/scale/rotate), Extrude depth, or a standard Sketch Dimension — instantly validates and saves the entered value or formula.
> - **Focus Release:** The text cursor is immediately removed from the field, transferring focus back to the canvas viewport so standard hotkeys (panning/zooming) work again.
> - **Context-Aware Tool Closure:** *For persistent tools (like Dimensioning):* saves the value, closes that floating input pop-up, but keeps the global Dimension tool active so the next line can be clicked immediately. *For single-action tools (like Offset or Move):* commits the geometry modification and completely exits the tool mode, returning to the standard Select Arrow.
> - **Error Handling:** If `ENTER` is pressed on an invalid formula or conflicting constraint, the field does not close — it flashes a red border, highlights the problematic text, and keeps focus for immediate correction.

---

## 6. New shape/geometry creation tools

- [x] **Group 6 done** — implemented 2026-06-17; builds clean; marked In Progress in Linear. MAS-118 polygon tool (Shapes flyout, live preview, closed editable polyline); MAS-128 scale tool (live drag gizmo + from-center/from-point pivot + factor field). MAS-118 sides set via panel stepper not mid-drag Tab (noted in Linear).

### MAS-118 — Polygon shapes
> Expand the **Shapes** nested flyout menu by adding a native **Polygon tool**. This will allow users to generate closed, multi-sided geometric primitives directly on the canvas.
>
> **User Workflow & Interaction**
> 1. **Activation:** The user hovers or long-presses the **Shapes** icon in the toolbar and selects the **Polygon** option.
> 2. **Initial Interaction:** Click-and-drag on the canvas defines the center point and the initial radius/rotation of the polygon.
> 3. **Dynamic Sides Field:** While dragging to size the polygon, a floating input pill appears next to the cursor defaulting to `Sides: 6`. Pressing `Tab` switches focus to the Sides field, allowing the user to type a new integer (e.g. `5` for a pentagon, `8` for an octagon) dynamically before committing.
> 4. **Commit:** Pressing `ENTER` or releasing the click bakes the polygon onto the canvas as fully editable sketch lines.
>
> **Implementation Requirements**
> - Add a clean, geometric polygon icon matching the stroke weight of the existing shape primitives.
> - Position the new tool inside the **Shapes** flyout, alongside existing primitives.
> - Integrate the polygon generator with the core sketch engine so it outputs standard, connected geometry lines that respect global constraints.

### MAS-128 — Scaling tool
> Add a tool to scale sketches, either from a scaling point or from it's own center

---

## 7. Patterning & mirroring
*Both are "replicate geometry" features that build on the dimension/precision-input system above; sewing v2's Phase 2 explicitly depends on the Mirror Tool core.*

- [x] **Group 7 done** — implemented 2026-06-17; builds clean; Python tests pass; marked In Progress in Linear. MAS-113 patterning v2 (rect+circular modes, dynamic ghost preview, circular center pick, new pattern_circular op); MAS-119 mirroring (Objects/Mirror-Line modes, dynamic ghost preview, OK/Cancel panel). Bounded deferrals (draggable handles/inline pills, suppression, associativity glyphs) noted in Linear comments.

### MAS-113 — Patterning v2
> **1. Tool Activation & Mode Selection** — Same as before; an improvement of the current, lackluster patterning tool. **Selection Behavior:** the user clicks the specific sketch lines, curves, or points to replicate. *Rectangular:* click a sketch line or axis to define the alignment vector for the grid rows/columns (defaults to horizontal/vertical workspace axes if unselected). *Circular:* click a sketch point, origin point, or circular arc center to act as the rotation pivot.
>
> **2. Interactive Canvas Gizmos & Previews** — **Dynamic Ghosting:** replicated geometry instantly appears as a dashed, semi-transparent preview that updates dynamically. **Rectangular Pattern Handles:** two perpendicular arrow manipulators at the center of the selection; dragging extends the pattern distance along that axis; a floating numerical pill shows/edits the instance count. **Circular Pattern Handles:** a circular grab-handle ring centered on the pivot; dragging expands/contracts the angular distribution; matching instance-count pill.
>
> **3. Pattern Types & Distribution Controls** — **Rectangular:** Distance Type toggle (Extent vs Spacing), Direction Type toggle (One Direction vs Symmetric), separate Quantity/Distance inputs per direction. **Circular:** Pattern Type (Full / Partial with a user angle / Symmetric).
>
> **4. Suppression & Instance Behavior** — Every preview instance has a small clickable checkbox/node to suppress it individually (gaps in a grid or wheel pattern). **Associative Constraints:** once committed via `ENTER`, generated geometry is linked by an underlying pattern constraint; changing a master dimension or the original sketch curves forces all instances to update uniformly; a persistent pattern glyph on the canvas re-opens the panel on double-click.

### MAS-119 — Mirroring Improvements
> *(THIS IS AN IMPROVEMENT, don't completely reck the twin-positioning of a line system, integrate that with this)*
>
> **1. Tool Activation & Selection Mode** — Trigger: from the `...` (Other Tools) flyout, or a shortcut. A floating options panel opens on the right, defaulting to **Objects** selection mode. **Objects (default):** click the sketch lines/curves/points/profiles to mirror. **Mirror Line:** switch modes via a panel toggle, then select a single straight line, construction line, or axis as the symmetry plane.
>
> **2. Interactive Canvas Previews** — **Dynamic Ghosting:** the moment a valid Mirror Line is selected, a ghosted, semi-transparent preview of the mirrored geometry instantly appears on the opposite side. **Real-Time Updates:** adding/removing items from the Objects selection while the Mirror Line is active updates the preview immediately.
>
> **3. Symmetrical Constraints & Mirror Dependency** — Once committed via `ENTER`/"OK", a persistent symmetry constraint icon appears between corresponding nodes/lines. **Downstream Associativity:** modifying the original source geometry symmetrically updates the mirrored geometry; modifying the Mirror Line itself updates the orientation/position of the entire mirrored block. **Breaking Symmetry:** deleting the symmetry glyph or one of the mirrored lines safely unlinks the association into independent sketch lines.
>
> **4. Right-Hand Active Tool Options Panel** — Objects Select Box (count + clear "X"), Mirror Line Select Box (active axis name/ID), "OK" to commit or "Cancel" (`ESC`) to drop the tool.

---

## 8. Sewing engine & hole placement
*Phase 2 of the sewing master doc explicitly depends on the Mirror Tool (group 7); hole-placement bugs belong in the same subject.*

- [x] **Group 8 done** — 2026-06-17; builds clean; Python tests pass; marked In Progress in Linear. MAS-106 line-proximity-filter fixed (crossing lines now filter holes; verified). MAS-120 Phase 1 (Keep-Out / Gap-Mode avoidance) implemented + wired; Phases 2-4 remain per the epic's sequential structure (Phase 2 needs Mirror associativity, itself deferred) — MAS-120 stays In Progress until all phases done.

### MAS-120 — Sewing tool v2 -- advanced, master document
> To position Pathstitch as a professional tool for leatherworking and fabrication, the sewing line feature must transition from a basic line-offset generator into an advanced parametric engine. This engine will dynamically manage obstruction avoidance, ensure perfect stitch-index alignment for flipped mirrored pieces, and inject physical registration markers.
>
> Due to the algorithmic and math-heavy nature of this feature, execution is split into four distinct, sequential phases.
>
> **Phase 1: Proximity Avoidance Zones (Keep-Out Constraints)** — Dependencies: None.
> - **Keep-Out Designation:** tag any internal geometry or path group as a `Keep-Out Element`.
> - **Clearance Math:** bounding radius around keep-out paths based on a user-defined clearance parameter (C).
> - **Path Rerouting Algorithms:** *Contour Mode:* Minkowski sum / parallel offset curve to route around the keep-out perimeter at exactly distance C. *Gap Mode:* detect intersections, slice the sewing path array, terminate stitch generation at -C and resume at +C.
>
> **Phase 2: Dynamic Flip-and-Match Symmetry** — Dependencies: Phase 1, Mirror Tool Core.
> - **Absolute Mirror Punching:** when a sewing path is mirrored across an axis, hole vector coordinates are explicitly mirrored relative to the origin, preventing accumulation errors.
> - **Stitch Index Anchoring:** a master index reference point (`Stitch_001`) pinned to a shared physical edge on both the original and mirrored patterns.
> - **Flipped Alignment Verification:** if the pattern is cut, flipped 180° horizontally, and stacked flesh-to-flesh, `Stitch_N` on piece A must precisely map to `Stitch_N` on piece B.
>
> **Phase 3: Interlocking Registration & Differential Pitch** — Dependencies: Phase 2.
> - **Alignment Node Injection:** option to replace standard stitch holes with custom geometry (e.g. a 1.5 mm alignment keyhole) at vertices or user-defined step intervals.
> - **Differential Curve Pitch Matching:** for joining 3D curved gussets to flat panels, true arc-length parameterization so the engine compresses/expands stitch pitch on the curved path relative to the flat path so total hole counts match across uneven boundary lengths.
>
> **Phase 4: UI Integration & Profile Management** — Dependencies: Phase 1, 2, 3.
> - **Contextual Active Panel:** numerical fields when the Sewing tool is engaged — `Pitch`, `Margin`, `Avoidance Radius` (toggle + numeric), `Symmetry Anchor` (axis picker).
> - **Live Vector Overlay Preview:** ghosted layout previews of paths/gaps/registration keys before confirming via `ENTER`.
>
> **Acceptance Criteria:** sewing lines accurately map around hardware keep-out zones without crossing boundaries; asymmetrical pattern sheets line up hole-for-hole when physically inverted; curved and flat sewing segments retain 1:1 hole-count correlation; all options accessible and real-time reactive via the right-hand panel.

### MAS-106 — hole algorithims
> Line proximity filter doesn't work — there are still lines that are out of place and crossing a line

---

## 9. Image import & reference content

- [x] **Group 9 done**

### MAS-108 — Image Addition
> **1. Import Trigger & Initial State** — Entry points: `File > Import` (autodetect as image, supports all major formats including niche ones like webp, avif, tiff, heic) or drag-and-drop onto the canvas. Drop position centers on the viewport (menu import) or on the cursor (drag-drop). Default Mode: instantly enters **Reference Image Mode** at 50% opacity so underlying sketch geometry stays visible.
>
> **2. Immediate Transform State (The Gizmo)** — A 2D/3D transform gizmo activates at the bounding box center on landing. Center handle = free translation, corner handles = proportional scaling, edge handles = non-proportional stretching (`Shift` toggles proportional), outer ring = rotation. `ENTER` or click-outside confirms/bakes; `ESC` cancels the import or reverts to the last committed transform.
>
> **3. Selection & Right-Hand Properties Panel** — Clicking the image re-highlights the bounding box and populates the panel: Opacity slider, Layer depth (front/back), visibility/lock toggles, "Edit Transform" button.
>
> **4. Vectorization Context (The "Trace" Workflow)** — A "Trace Image" button switches the panel into Vectorization Options (Threshold, Corner Smoothness, Path Optimization) with a live high-contrast vector preview overlay. A "Back to Reference"/"Cancel" button always reverts without losing the image. "Generate Vectors" converts the contrast lines into native editable sketch splines/lines and hides the source image.
>
> **Image Trace Tolerance Adjustment (important)** — A Tolerance/Detail slider (1–100) in the panel during Trace Mode dynamically updates the vector outline live. Low sensitivity (1–30) filters noise into smooth, simplified geometry with fewer nodes; high sensitivity (70–100) captures intricate paths/sharp corners/fine textures as a denser cluster of splines/control points. Left/right arrow keys fine-tune the focused slider by single-digit increments.

### MAS-137 — Reference images
> When reference images are imported, they get their own layer (and a layer type that can ONLY hold reference images). They aren't selectable just using the viewport — if a user wants to select it, they have to click on the layer containing the reference image. Then, under the active tool options panel, they can change settings such as opacity, scale, and move it, and do things such as calibrate it.
>
> As well as that, control their sizes to be completely fitting inside of what the viewport can see at the time of import.

---

## 10. Text system

- [x] **Group 10 done** — implemented 2026-06-19; builds clean; Python tests pass. MAS-134 font picker (every installed device font) on the Text tool panel and the selected-text properties panel; MAS-135 multi-line inline editor (auto-focused + select-all on creation, Shift+Enter newline, Enter commits), live font / font-size (seeded from the drawn box) / character-spacing / bold / italic / underline, and text-specific options in the active-tool panel when a text is selected. Rich styling persists through the DXF mirror (and .stch saves) via XDATA.

### MAS-134 — Text fonts
> On selecting the create text with the selection tool OR on creation with the text tool, have there be the option for fonts to be changed, and make the available fonts every font installed on the device

### MAS-135 — Text v3
> When text bounding box is set, anything else being typed then without doing any other action goes right into the text, typing it. On creation, that field is auto-selected, basically.
>
> Also, have text-specific options in the Active tool bar when text is selected.
> - Fonts (as another issue documents)
> - Font size (the starting number is defined as the bounding box set by the user)
> - Text spacing (how far away each character is away from each other (also adds on tho spaces)
> - Italics/bold/underline/etc
> - Shift+enter -> new line

---

## 11. Layers

- [x] **Group 11 done** — implemented 2026-06-19; builds clean; marked In Progress in Linear for review. MAS-105: clicking a layer in the panel now selects every geometry entity it contains (`selectAllInLayer`), the inverse of the existing selection→active-layer sync; a reference-image layer just activates (no viewport geometry), and an empty layer still activates as the draw target.

### MAS-105 — Layers v2
> Clicking on a layer selects all the geometries that are in that layer

---

## 12. 3D workspace
*Groups its 3D-only concerns together; unwrapping work specifically should stay In Progress until every phase is complete per the issue's own instruction.*

- [x] **Group 12 done** — implemented 2026-06-19; builds clean; Python tests pass; marked In Progress in Linear. MAS-122 (Home → default view when canvas empty), MAS-126 (plane imports only intersected geometry; full-silhouette only when nothing intersects — Python-verified), MAS-123 (live darker-blue cross-section preview as the plane moves), MAS-125 (drag a model into an open 3D workspace → append + distribute via new `combine_steps` op; body move tool — click-select + 3D TransformControls gizmo + precise X/Y/Z panel + persisted per-body offsets), MAS-112 (Phase-2 LSCM conformal flattening of doubly-curved faces, numpy-only — verified ~0° distortion on developables, finite sphere flatten). **MAS-112 stays In Progress** per its own rule (full Phase-2 modes/heatmap/connected-net integration + Phases 3–4 remain). The 3D viewport gizmo/preview pieces are code-complete but not runtime-verified here (no computer-use testing).

### MAS-125 — 3D model imports
> Allow users to drag in a 3D model in an already open 3D workspace that has a model loaded currently. Use best distribution to distribute them.
>
> As well as that, add a move tool for the bodies, so that the user can select the bodies (by clicking on them) and move them around using draggable three dimensional gizmos. Have the active tool options have details for how far it moves, and ability to change it to have precise movement.

### MAS-126 — 3D plane details
> The 3D plane should only import the 3D geometry that it intersects, not all 3D geometry visible. The only time that it will import all geometry visible (what it's doing right now) is when it doesn't intersect with anything.

### MAS-123 — Plane Projection Sketch v2
> Add a preview to the cross section of the body (bodies) made by the plane — highlight them in a darker shade of blue than the shade of the plane

### MAS-122 — Home v2
> If there is nothing on the canvas and home is pressed, just return to how the software opens up (at that scale and at that origin position)

### MAS-112 — Unwrapping
> This is an issue reminding, when the time is right, to finish the next phase (whatever it may be) of unwrapping as documented in unfold.md (/Users/chen/Documents/Assets/Pathstitch/unfold.md). Don't mark this anything above In Progress (In Progress itself is ok) until it is fully done (all phases complete and flawless).

---

## 13. Export & file previews

- [ ] **Group 13 done**

### MAS-136 — Exporting
> Exporting straight up doesn't work. Also, show a check mark indicator next to "Export Selected Only" and "Export Measurement Lines" to show weather they are on or not. Also, change which format is checked if the user clicks another one in the export format. And the export button itself in the menu bar is always grayed out, so the user just can't export.

### MAS-124 — Quicklook Previews
> Make .dxf file quicklook preview have much better handling of curves. In the preview, some (most) curves don't show up if it's something irregular, like a G2 curve. Fix that, and make ALL geometry show up.
>
> In addition to that, made .step previews much better. The onboard MacOS .stl preview involves having a window with a rendered 3D mesh that the user can drag around and preview. Have that, but not with three.js, but with a native MacOS thing, to make it lightning fast while still being powerful and robust.

---

## 14. Search & keybinds
*App-wide utility/settings — low dependency on everything above, can land any time.*

- [ ] **Group 14 done**

### MAS-133 — Search menu
> Make sure the search menu has all the most up-to-date tools, keyboard shortcuts, and fix this bug:
>
> When the cursor gets close to either the top or bottom of the search results area, it scrolls very fast in that direction. Remove that. Have the cursor simply select, not dictate where it is.
>
> Using the arrow keys to go up/down glitches and the selection teleports back (this is related to the cursor bug above, if the cursor is not on the results, then it's fine). Fix that, the arrow key can go through all of them, the results scrolling along with it.

### MAS-132 — Keyboard shortcuts
> The keyboard shortcut in settings are just straight off. Make it accurate. For example, search is showing up as 's', but it's not 's', it's CMD K. 's' brings us to holes & sewing, which itself is 'd' (and d works). In this case, make search 's'.

---

## 15. Documentation catch-up
*Must come last — it's explicitly "update everything" once the other changes have landed.*

- [ ] **Group 15 done**

### MAS-129 — Update everything
> With all the new changes, update the readme, update the documentation, update menu bar -> tools, update everything that needs catching up on
