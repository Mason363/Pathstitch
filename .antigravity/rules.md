# Pathstitch Project Rules

- All CAD geometry logic lives in Python (pathstitch_core/), never in Swift
- Swift calls Python via Process() with JSON stdin/stdout
- Use @Observable macro, never ObservableObject
- Use async/await, never Combine
- Python env: /opt/homebrew/Caskroom/miniconda/base/envs/pathstitch/bin/python
- DXF library: ezdxf. STEP library: pythonocc-core. Geometry: shapely
- Default unit: mm
- Visual design: Plasticity aesthetic (dark #0d0d10 base, see PATHSTITCH_PROMPT.md Design Tokens)
- No border-radius > 4px, no glassmorphism, no gradients in UI
- No third-party Swift packages for geometry
- Output files always go to user-specified path or /tmp/pathstitch/, never overwrite input
- Commit after every working feature increment
- Sewing holes algorithm: reference /Users/chen/Documents/Assets/Laser Cut Design Website
- Project root: /Users/chen/Documents/Assets/Pathstitch
