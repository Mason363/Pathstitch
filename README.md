<h1 align="center">Pathstitch</h1>

<p align="center"><b>A native macOS CAD/CAM studio for leathercraft, pattern making, and sewing.</b></p>

<p align="center">
  <img alt="Platform: macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white">
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-arm64-0a84ff">
  <img alt="Built with SwiftUI" src="https://img.shields.io/badge/SwiftUI-orange?logo=swift&logoColor=white">
  <img alt="Engine: Python" src="https://img.shields.io/badge/engine-Python%20%2B%20OpenCASCADE-3776AB?logo=python&logoColor=white">
  <img alt="Release v1.0.0" src="https://img.shields.io/badge/release-v1.0.0-success">
</p>

Pathstitch is for makers who want **CAD precision without CAD overhead**. Sketch a pattern with snapping and
live dimensions, round corners parametrically, drop in saddle‑stitch holes and glue tabs, then export
cut‑ready DXF/SVG/PDF — or import a 3D `.step` model and **unfold it into flat panels** you can actually cut
and sew. It's a fast, native SwiftUI app backed by a real geometry kernel (`ezdxf`, `shapely`, OpenCASCADE),
not a web wrapper.

https://github.com/user-attachments/assets/50c6973c-2bd9-470b-b031-fa0a991badef

<img width="1313" height="913" alt="Screenshot 2026-06-15 at 4 52 39 PM" src="https://github.com/user-attachments/assets/63cfbd20-b581-47fe-a3eb-1ff0c9cac5cb" />

---

## Download

**[⬇ Download the latest release](https://github.com/Mason363/pathstitch/releases/latest)** — grab
`Pathstitch-x.y.z.dmg`, drag it into Applications, and you're running. No Python, no setup; the geometry
engine ships inside the app.

- **Requires:** an Apple‑Silicon Mac (M1 or newer) on **macOS 14 (Sonoma)+**.
- **Free, and you don't need an Apple Developer account to run it.** The app is **ad‑hoc signed, not
  Apple‑notarized** (notarization needs a paid $99/yr Apple Developer ID, which this project doesn't have
  yet), so the very first launch needs a **one‑time** Gatekeeper approval — a 15‑second, two‑click bypass.
  See **[Installing](#installing-the-app)**. After that first approval it opens normally forever.

---

## What it does

### Draw
Line, circle, rectangle, polygon, text, and an Illustrator‑style **pen** tool, all with point/edge/grid **snapping** and
**on‑creation dimensions** — type a width, `Tab`, type a height, `Enter`, done. No modal dialogs, no hunting through panels: the number you want is already
under your cursor.

> [VIDEO: 8–12s loop — drawing one rectangle by typing exact dimensions (e.g. 80 `Tab` 50 `Enter`), then a circle snapping to its corner. Keep keystrokes visible on screen so people see the type-a-number-and-go flow. Silent loop, no narration needed.]

<img width="1313" height="913" alt="Screenshot 2026-06-15 at 4 53 33 PM" src="https://github.com/user-attachments/assets/e4abe9a9-303a-477e-a92a-b73f2b6d0251" />

### Edit
- **Parametric fillet & chamfer** (G1/G2). Every corner is independent, draggable to size, and stays
  editable forever — it can even grow until adjacent fillets meet. Works on polylines, the corner where two
  separate lines meet, and imported geometry.
- **Trim**, Fusion‑style: hover a segment to see exactly what will be removed, then click — or drag across
  several — to cut at every intersection.
- **Boolean** union / subtract / intersect on closed shapes, and **Explode** to break a compound back into
  its individual edges.
- Move/rotate gizmo, point‑to‑point move, scale, mirror, reflect, duplicate.

https://github.com/user-attachments/assets/d9a70b49-feea-481b-a810-f7070c761132

<img width="1313" height="913" alt="Screenshot 2026-06-15 at 4 54 20 PM" src="https://github.com/user-attachments/assets/85944b0c-71b1-4632-8773-ce5b9ddc906c" />

<img width="1313" height="913" alt="Screenshot 2026-06-15 at 4 56 42 PM" src="https://github.com/user-attachments/assets/b6631183-029f-43dc-8e88-8190f379d08b" />

### Make
- **Stitch holes & saddle‑stitch patterns** generated along any path, with spacing and corner controls.
- **Offset**, **convert‑lines** (dashed/perforated styles), **fill / hatch** a closed region,
  **patterning** (grid, circular, or along a path), and **paper folding** (crease lines + glue tabs) for
  assembling 3D objects from flat stock.

https://github.com/user-attachments/assets/3a78569e-ba0d-49fa-87fd-ac4246746713

<img width="1313" height="913" alt="Screenshot 2026-06-15 at 5 03 09 PM" src="https://github.com/user-attachments/assets/5959eb5d-2da1-4abb-9f9f-e1c15734566c" />

### Go 3D → 2D
Import `.step` / `.stp`, inspect it in a Three.js viewport, and **unfold developable surfaces into flat
nets** ready for the 2D tools — the thing most pattern tools simply can't do. Drag in several models at once
and they auto‑arrange; take a cross‑section from any plane to sketch against.


https://github.com/user-attachments/assets/08f13caf-7b4b-474f-868d-88ccc729f6be


<img width="1312" height="912" alt="Screenshot 2026-06-15 at 5 05 53 PM" src="https://github.com/user-attachments/assets/802bf6e9-4b0f-4159-962b-fa0768eef29b" />

<img width="1312" height="912" alt="Screenshot 2026-06-15 at 5 06 01 PM" src="https://github.com/user-attachments/assets/dde22397-fa07-4e84-a05b-7b8d92b379c0" />

### Export & integrate
DXF, SVG, PDF, and PNG export; native `.stch` project files; and **Finder QuickLook previews + thumbnails**
for DXF and STEP — press Space on a file and see the real geometry, not a generic icon. Plus the niceties:
customizable keybinds, light/dark themes, a `⌘K` command palette, and a rearrangeable toolbar.

https://github.com/user-attachments/assets/903794b1-4d92-4840-8783-a3f5c49ae1bd

---

## Feature list

### Available now

**Draw**
- **Line / Circle / Rectangle** — core primitives with live dimensions.
- **Polygon** — N-sided shapes, drag to set radius/rotation, tab for sides.
- **Text v3** — double-click to edit inline, choose system fonts, adjust size, spacing, bold, italic, underline, and multi-line.
- **Pen** — Illustrator-style bézier paths.
- **Snapping** — point/edge/grid snapping while drawing.
- **Reference images** — import, calibrate, transform, and trace/vectorize image underlays.

**Edit**
- **Fillet / Chamfer** — parametric, per-corner, G1/G2, draggable; shared radius for corners picked together.
- **Trim** — hover-to-preview, click or drag to cut at intersections.
- **Offset** — chain-select, live ghost, flip side, construction lines.
- **Join / Cleanup** — bridge hanging endpoints with straight lines.
- **Convert Lines** — restyle to dashed / perforated / decorative lines.
- **Boolean** — union, subtract, and intersect closed shapes.
- **Fill / Hatch** — fill a closed region with a solid or hatch pattern.
- **Explode** — break a compound / polyline back into its individual edges.
- **Move** — gizmo + exact point-to-point.
- **Scale** — live drag, from center or a picked point.
- **Mirror** — objects/mirror-line modes with live ghost.
- **Reflect / Flip / Duplicate** — quick transforms.
- **Layers v2** — organize geometry by layer; click a layer in the panel to select its geometry.

**Measure & dimension**
- **Measure** — ad-hoc distance lines.
- **Dimension** — linear / radius / point-to-point with a parameter engine (formulas, variables, units, `fx:`/driven).

**Make**
- **Stitch holes** — saddle-stitch generation along any path, spacing/corner controls.
- **Keep-out avoidance** — gap the stitch line around tagged hardware.
- **Patterning** — rectangular, circular, and along-a-path arrays with live ghost preview.
- **Paper folding** — crease lines + glue tabs for 3D assembly.

**3D → 2D**
- **STEP import** — load `.step` / `.stp` into a 3D viewport.
- **3D bodies** — drag-and-drop to import multiple 3D models with auto-distribution and 3D translation gizmos; plane cross-section previews.
- **Plane projection** — sketch from a cutting plane with cross-section previews.
- **Unfold & Unwrapping** — flatten developable surfaces and doubly-curved faces (conformal LSCM).
- **Home v2** — press Home to frame all geometry or return to the default startup view if the canvas is empty.

**Export & integrate**
- **Export** — DXF, SVG, PDF, PNG with filters for selected-only or measurements and clear indicator checkmarks.
- **Projects** — native `.stch` files.
- **QuickLook Previews** — Finder previews + thumbnails for DXF (full curve support) & STEP (native fast 3D renderer).
- **Batch mode** — operate over many files at once.

**Workspace**
- **Command palette** — search-optimized palette (`S` or `⌘K`) to find and run any tool.
- **Keybinds & themes** — customizable shortcuts and appearance (light/dark).
- **Toolbar** — zoned, rearrangeable, resizable panels with collapsible options.
- **Recent projects** — welcome screen with reveal/remove.

### Keyboard shortcuts

Single-key, Fusion/Photoshop-style defaults (all rebindable in Preferences → Shortcuts, taking effect immediately. Secondary standard macOS shortcuts like `⌘K` for search are also supported).

| Key | Tool | Key | Tool | Key | Action |
|-----|------|-----|------|-----|--------|
| `V` | Select | `L` | Line | `S` / `⌘K` | Search |
| `M` | Move | `C` | Circle | `⌘Z` / `⌘⇧Z` | Undo / Redo |
| `H` | Pan | `R` | Rectangle | `⌘D` | Duplicate |
| `O` | Offset | `P` | Pen | `⌫` | Delete |
| `T` | Trim | `D` | Dimension | `⌘⇧H` / `⌘⇧J` | Flip H / V |
| `F` | Fillet | `I` | Measure | `N` | Toggle snapping |
| `B` | Chamfer | `E` | Convert Lines | `A` | Toggle chain-select |
| `G` | Add Holes | `J` | Join / Cleanup | `⇧G` | Toggle grid |

Tools without a default key (Scale, Polygon, Text, Mirror, Patterning, Paper Folding) are reachable from the toolbar or the search palette, and can be bound in Preferences.

### Coming soon

- **Angular dimensions** — angle between two lines.
- **Dimension associativity** — edit a master value, dependents follow.
- **Scale-on-first-dimension** — proportional whole-sketch scaling.
- **Pattern/mirror handles** — draggable gizmos, instance suppression, associative links.
- **Sewing v2 (phases 2-4)** — flip-match symmetry, registration keyholes, differential pitch, saved profiles.
- **Unwrapping (Phases 3-4)** — advanced connected net flattening and nesting.

---

## Under the hood

Pathstitch is a thin, fast SwiftUI front‑end over a persistent Python geometry worker. The UI never blocks on
geometry: every operation is a JSON request streamed to a long‑lived backend process and rendered back.

```
┌──────────────────────────────┐        JSON over stdin/stdout        ┌────────────────────────────┐
│  SwiftUI front-end (macOS)    │  ─────────────────────────────────▶ │  Python engine             │
│  AppState · DxfCanvasView ·   │   PythonBridge ↔ pathstitch_core    │  ezdxf · shapely · numpy   │
│  ThreeDViewport (WKWebView)   │  ◀───────────────────────────────── │  pythonOCC (STEP) ·        │
└──────────────────────────────┘                                      │  matplotlib (PDF/PNG)      │
                                                                       └────────────────────────────┘
```

- **Front‑end** — Swift / SwiftUI (`Pathstitch/Pathstitch`). `PythonBridge.swift` keeps one
  `python -m pathstitch_core.worker` process alive and streams framed JSON to it.
- **Engine** — `pathstitch_core/`: `dxf_ops.py` (2D), `step_ops.py` / `surface_unfold.py` /
  `net_unfold.py` (3D & unfolding), driven by `worker.py`.
- **3D viewport** — `viewport3d.html` (Three.js) inside a `WKWebView`.

For a packaged build, a trimmed copy of the Python environment and the engine are bundled into
`Pathstitch.app/Contents/Resources/`, so the shipped app has no external dependencies.

---

## Build from source

You only need this if you want to develop Pathstitch; end users just download the `.dmg`.

**Requirements**

| Component | Version | Notes |
|---|---|---|
| **macOS** | **14.0 (Sonoma)+** | Developed/tested on macOS 26. |
| **Xcode** | **16+** | Built with Xcode 26.5 / Swift 6.3. |
| **Python** | **3.11** | The geometry backend. |

**Python packages** (`pathstitch_core/requirements.txt` + 3D/raster extras):

```
ezdxf          # DXF read/write + 2D geometry
shapely        # offsets, booleans, polygon ops
numpy          # math
svgwrite       # SVG export
matplotlib     # PDF / PNG raster export
pythonocc-core # STEP import + 3D (OpenCASCADE) — install via conda-forge, not pip
```

**Steps**

```bash
# 1. clone
git clone https://github.com/Mason363/pathstitch.git
cd pathstitch

# 2. backend env (conda recommended for pythonocc-core)
conda create -n pathstitch python=3.11
conda activate pathstitch
conda install -c conda-forge pythonocc-core
pip install -r pathstitch_core/requirements.txt matplotlib

# 3. sanity check the engine
PYTHONPATH=. python pathstitch_core/test_dxf_ops.py   # → "ALL TESTS PASSED SUCCESSFULLY!"
```

When run **from Xcode**, the app falls back to your local interpreter + repo. Set the two fallback paths
once near the top of
[`Pathstitch/Pathstitch/Bridge/PythonBridge.swift`](Pathstitch/Pathstitch/Bridge/PythonBridge.swift):

```swift
"/opt/homebrew/Caskroom/miniconda/base/envs/pathstitch/bin/python"  // your env (echo $CONDA_PREFIX/bin/python)
"/absolute/path/to/this/repo"                                       // this checkout
```

Then open `Pathstitch/Pathstitch.xcodeproj` and ⌘R (or `xcodebuild ... -configuration Debug build`).

---

## Packaging a distributable `.dmg`

One command produces a self‑contained, drag‑to‑install image:

```bash
bash scripts/package_app.sh
# → dist/Pathstitch-1.0.dmg   (~400 MB, self-contained, ad-hoc signed)
```

It builds the Release app, copies a **trimmed** Python env (≈2.8 GB → ≈1.1 GB — OpenCASCADE stays; dev‑only
LLVM/Qt/VTK/headers are dropped) plus `pathstitch_core` into the bundle, ad‑hoc signs it, and creates a
`.dmg` whose window has the app next to an **Applications** shortcut (drag one onto the other). Point it at a
different env with `CONDA_ENV=/path/to/env bash scripts/package_app.sh`.

**Styled installer window.** Drop a `scripts/dmg/background.png` (500 × 500) and the packager builds a
positioned drag‑to‑Applications window over your artwork; without it you get a plain (but still functional)
drag‑install DMG. Use **`scripts/dmg/background-template.svg`** as the guide — it marks exactly where the app
and Applications icons land so you can paint a matching background (e.g. a leather‑cut texture). See
`scripts/dmg/README.md`.

> The bundled env is **arm64**, so the image targets Apple‑Silicon Macs. For a no‑warning install you'd need a
> paid **Apple Developer ID** signature + notarization (`xcrun notarytool`); without it, users do the
> one‑time bypass below.

---

## Installing the app

Because Pathstitch isn't Apple‑notarized, Gatekeeper warns on first launch. Do this **once**:

1. Open the `.dmg`, drag **Pathstitch** onto **Applications**, and double‑click it.
2. On the “…cannot be opened because Apple cannot check it…” dialog, click **Done**.
3. Go to **System Settings ▸ Privacy & Security**, scroll down, and click **Open Anyway** next to the
   Pathstitch message. Confirm with Touch ID / your password.

*(Terminal alternative, if you trust the source: `xattr -dr com.apple.quarantine /Applications/Pathstitch.app`.)*

**Checking your macOS version:**  ▸ About This Mac, or `sw_vers -productVersion` (needs `14.0`+).

### Automatic updates

Pathstitch updates itself with [Sparkle](https://sparkle-project.org). On the second launch it asks whether
to check for updates automatically; you can change that any time in **Pathstitch ▸ About Pathstitch** (the
**Check for Updates…** button and the **Automatically check for updates** toggle), or via
**Pathstitch ▸ Check for Updates…**. Your settings persist across updates.

**Cutting a release (maintainer):**

1. Bump `MARKETING_VERSION` *and* `CURRENT_PROJECT_VERSION` (Sparkle compares the build number) in the
   Xcode target.
2. `bash scripts/package_app.sh` → `dist/Pathstitch-<version>.dmg`.
3. `bash scripts/make_appcast.sh <version>` → signs the dmg (EdDSA key in your login Keychain) and writes
   `dist/appcast.xml`.
4. `gh release create v<version> dist/Pathstitch-<version>.dmg dist/appcast.xml --title "…" --notes "…"`.

The app's feed (`SUFeedURL`) points at `releases/latest/download/appcast.xml`, so uploading the appcast as a
release asset is all it takes for existing installs to see the update. The EdDSA **public** key lives in
`Info.plist` (`SUPublicEDKey`); keep the **private** key (in your Keychain) backed up — losing it means no
future signed updates.

---

## Project layout

```
pathstitch/
├── Pathstitch/                     # Xcode project + Swift sources
│   ├── Pathstitch.xcodeproj
│   ├── Pathstitch/                 # main app target (App/, Bridge/, Modes/, Welcome/)
│   ├── DxfPreviewer/               # QuickLook preview extension
│   └── PathstitchThumbnail/        # Finder thumbnail extension
├── pathstitch_core/                # Python geometry engine (worker.py, dxf_ops.py, *unfold*.py)
├── scripts/package_app.sh          # build a self-contained .dmg
├── scripts/make_appcast.sh         # sign the dmg + emit the Sparkle appcast.xml
└── README.md
```

---

## Status & roadmap

Pathstitch is an actively developed **1.0**. The 2D pipeline (draw → edit → stitch → export) is the mature
core; 3D STEP import + unfolding works for developable surfaces and is expanding. Currently **Apple‑Silicon
only** — an Intel/universal build is possible by repackaging the backend on an Intel Mac.

---

## Feedback & bug reports

Found a bug, hit a rough edge, or have an idea? It genuinely helps.

- **🐛 Bugs** → [open an issue](https://github.com/Mason363/Pathstitch/issues/new?template=bug_report.yml).
  Steps to reproduce + a screenshot or short screen recording make it far easier to fix — visual and
  interaction bugs especially.
- **💡 Feature requests** → [open an issue](https://github.com/Mason363/Pathstitch/issues/new?template=feature_request.yml).
  Tell me what you're trying to *do*; the goal matters more than a specific implementation.
- **💬 Questions, ideas to talk through, or showing off what you made** →
  [Discussions](https://github.com/Mason363/Pathstitch/discussions).

Before filing, a quick search of [existing issues](https://github.com/Mason363/Pathstitch/issues) avoids
duplicates. That's it — no account hoops beyond a free GitHub login.

---

## Credits

Built with ❤️ by **Mason Chen**.

<sub>If Pathstitch saves you time, you can [buy me a coffee](https://buymeacoffee.com/masonchen). ☕</sub>
---

## License

Pathstitch is licensed under the **GNU General Public License v3.0** — see [LICENSE](LICENSE).

It uses [Potrace](https://potrace.sourceforge.net/) (GPL) for raster-to-vector tracing, which is why
Pathstitch as a whole is distributed under the GPLv3.

### Native STEP preview (foxtrot)

The Finder QuickLook preview/thumbnail for `.step` files tessellates the B-rep
into a triangle mesh using [foxtrot](https://github.com/Formlabs/foxtrot)
(MIT/Apache-2.0), wrapped as a small Rust static library in
[`native/step_mesh`](native/step_mesh). A prebuilt `lib/libstep_mesh.a` is
checked in so the Xcode build needs no Rust toolchain. To rebuild it (e.g. after
bumping the foxtrot pin), install [Rust](https://rustup.rs) and run
`native/step_mesh/build.sh`.
