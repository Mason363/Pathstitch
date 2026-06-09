# Pathstitch - Agent Onboarding & Technical Reference Manual

Welcome! This document outlines the system architecture, file map, toolchain configurations, and development workflows for the **Pathstitch** project. It is specifically designed to help AI coding agents onboard, build, test, and contribute to the repository seamlessly.

---

## 1. Project Overview

Pathstitch is a high-performance 2D CAD / 3D CAM design application for leathercraft, pattern making, and sewing projects.
- **Frontend**: macOS native SwiftUI application implementing vector sketching tools (lines, circles, rectangles, text annotations), measurement tools, and rendering.
- **Backend (Core)**: Python geometric vector engine wrapping `ezdxf` and `shapely` for vector operations, and `OCCT` (OpenCascade) / `trimesh` for 3D model parsing.
- **3D Viewport**: A Three.js web canvas running within a WKWebView, visualizing 3D sheet unfolds, stitch line overlays, and face highlights.

---

## 2. Architecture & Communication Flow

```mermaid
graph TD
    subgraph SwiftUI Frontend (Swift)
        AppState[AppState.swift] -->|JSON IPC Bridge| PythonBridge[PythonBridge.swift]
        AppState -->|Renders 2D| DxfCanvasView[DxfCanvasView.swift]
        AppState -->|Controls 3D Viewport| ThreeDViewport[ThreeDViewport.swift]
    end

    subgraph Web Viewport (Three.js)
        ThreeDViewport -->|Loads| ViewportHTML[viewport3d.html]
    end

    subgraph Python Backend (pathstitch_core)
        PythonBridge -->|Runs Command| DxfOps[dxf_ops.py]
        PythonBridge -->|Runs Command| StepOps[step_ops.py]
        DxfOps -->|CAD Library| ezdxf[ezdxf & shapely]
        StepOps -->|3D Library| OCCT[OpenCascade / CAD parsers]
    end
    
    ezdxf -->|Output DXF| AppState
```

### IPC Bridge Model
Swift-to-Python communication is handled by `PythonBridge.shared.run(module:op:args:)`.
- Inputs and arguments are serialized to JSON.
- Python modules (`dxf_ops.py`, `step_ops.py`) are invoked using CLI arguments (`--json`).
- Outputs are returned to Swift as JSON-deserializable dictionaries.

---

## 3. Directory Map

Key files and directories in the repository:

- [Pathstitch/](file:///Users/chen/Documents/Assets/Pathstitch/Pathstitch) — The macOS Xcode Project folder.
  - [Pathstitch/App/AppState.swift](file:///Users/chen/Documents/Assets/Pathstitch/Pathstitch/Pathstitch/App/AppState.swift) — Central application store, coordinates states, loads project files (`.stch`), triggers undo/redo log events, and manages the session temp folder URL.
  - [Pathstitch/Modes/TwoDMode/DxfCanvasView.swift](file:///Users/chen/Documents/Assets/Pathstitch/Pathstitch/Pathstitch/Modes/TwoDMode/DxfCanvasView.swift) — Native SwiftUI graphics context rendering drawn polylines, circles, measurements, text annotations, translation gizmo layout, and touchpad mouse interaction deltas.
  - [Pathstitch/Modes/ThreeDMode/ThreeDViewport.swift](file:///Users/chen/Documents/Assets/Pathstitch/Pathstitch/Pathstitch/Modes/ThreeDMode/ThreeDViewport.swift) — WKWebView wrapper managing communication hooks (`window.recenterCamera`, `window.highlightFace`) inside the Three.js canvas.
  - [Pathstitch/ContentView.swift](file:///Users/chen/Documents/Assets/Pathstitch/Pathstitch/Pathstitch/ContentView.swift) — Main application UI layout including tool sidebars, folding options, and custom overlay action sheets.
  - [Pathstitch/Welcome/](file:///Users/chen/Documents/Assets/Pathstitch/Pathstitch/Pathstitch/Welcome) — Welcome screen components (`WelcomeView.swift`, `WelcomeState.swift`, `WelcomeWindowController.swift`, `WindowManager.swift`, `PathstitchThumbnailLoader.swift`) for coordinating app startup, recent files queries, and card navigation.
  - [DxfPreviewer/](file:///Users/chen/Documents/Assets/Pathstitch/Pathstitch/DxfPreviewer) — Sandbox-compliant Quick Look Finder extension which parses DXF elements in pure Swift and draws previews using CoreGraphics.
  - [PathstitchThumbnail/](file:///Users/chen/Documents/Assets/Pathstitch/Pathstitch/PathstitchThumbnail) — Sandbox-compliant Finder Quick Look Thumbnail extension target which reads zipped `.stch` archives and serves `preview.png` thumbnails to Finder.
- [pathstitch_core/](file:///Users/chen/Documents/Assets/Pathstitch/pathstitch_core) — Python core geometry library.
  - [pathstitch_core/dxf_ops.py](file:///Users/chen/Documents/Assets/Pathstitch/pathstitch_core/dxf_ops.py) — ezdxf and Shapely logic for sewing hole distribution, curve offset calculations, grid/path patterns, SVG imports, and PDF traces.
  - [pathstitch_core/step_ops.py](file:///Users/chen/Documents/Assets/Pathstitch/pathstitch_core/step_ops.py) — 3D STEP file parsing, surface boundary extraction, and face-based unfold mappings.

---

## 4. Development Environment & Toolchain

### 4.1 Python Setup
The project uses a dedicated conda/miniconda python environment.
- **Python Binary Path**: `/opt/homebrew/Caskroom/miniconda/base/envs/pathstitch/bin/python`
- **Core Dependencies**:
  - `ezdxf` (DXF writing and loading)
  - `shapely` (computational geometry, parallel offsets, spatial intersects)
  - `pdfplumber` (extracting vector paths from PDF mockups)
  - `potracer` / `pypotracer` (tracing raster template images into CAD vectors)

### 4.2 Xcode Compilation
The workspace uses a standard Apple macOS application build chain.
- **Xcode Project File**: `Pathstitch/Pathstitch.xcodeproj`
- **Primary Scheme**: `Pathstitch` (compiles and bundles the host application, the `DxfPreviewer` Quick Look extension, and the `PathstitchThumbnail` Quick Look Thumbnail extension).

---

## 5. Build and Test CLI Commands

### Compile Xcode Project
To verify Swift code changes and compilation:
```bash
xcodebuild -project Pathstitch/Pathstitch.xcodeproj -scheme Pathstitch -configuration Debug
```

### Run Python Core Unit Tests
To verify modifications in the backend geometrical algorithms:
```bash
/opt/homebrew/Caskroom/miniconda/base/envs/pathstitch/bin/python -m pathstitch_core.test_dxf_ops
```

---

## 6. Critical Implementation Rules

### Rule 1: Temp Files Isolation (Anti-Collision)
- **Do not hardcode `/tmp/pathstitch` or `/tmp/pathstitch/active.dxf`**. This causes severe permission conflicts and cross-session data leaks.
- Always use `AppState.sessionTempDirectory` URL which resolves to an isolated, UUID-tagged folder inside `NSTemporaryDirectory()` (e.g. `/var/folders/.../pathstitch_UUID/`). 
- Pass this isolated URL parameter explicitly when invoking python operations.

### Rule 2: Polyline Closure Attributes
- In `ezdxf`, setting `"flags": 1` inside `dxfattribs` during polyline initialization is **not** sufficient to close shapes.
- Always write `"closed": True` or `"closed": is_closed` directly in `dxfattribs` when adding polylines (such as rectangles). When correctly flagged as closed, `shapely` offset operations compute precise closed loop parallels.

### Rule 3: Text Height and Width
- Text items in DXF files (`TEXT` dxftype) contain an insertion origin and a height, but lack a direct layout bounding box.
- For selection highlights, drag-bounds, and boundaries calculations on the canvas, estimate text width using the formula:
  $$\text{width} = \text{length of string} \times \text{height} \times 0.6$$

### Rule 4: Zipped Project Files & Backward Compatibility
- Project files saved as `.stch` are zipped archives.
- When loading a `.stch` project, the app must first try to open it as a zip archive and extract `project.json`. If that fails (e.g. for files created under earlier versions of Pathstitch), it must fall back to reading the raw JSON content directly.

### Rule 5: Keyboard Window Intercepts
- Global key shortcuts for the Welcome Screen window (such as Left/Right arrows for card navigation, Enter to open, Escape/Cmd+W to minimize) should be intercepted at the window level by overriding `sendEvent(_:)` in a custom `NSWindow` subclass to bypass SwiftUI responder focus lags.

### Rule 6: QuickLook Extensions & UTI Mappings
- The `.stch` document type is associated with the Uniform Type Identifier `com.chen.pathstitch.stch`.
- Any QuickLook preview or thumbnail extensions registered for `.stch` must specify this UTI in their `Info.plist` support declarations.

---

## 7. Git Collaboration Guidelines

- **Atomic Commits**: Keep backend Python changes and frontend Swift updates separated into clean, logical commits.
- **Derived Data Exclusion**: Ensure `/Users/chen/Library/Developer/Xcode/DerivedData` is ignored. Avoid committing temporary binary output artifacts.
