# DMG installer background

The release `.dmg` opens as a drag-to-install window: the Pathstitch app sits on
the left, the **Applications** folder on the right, and you drag one onto the
other.

## Make the leather background

1. Open **`background-template.svg`** in this folder. It shows the exact window
   size and where the two icons land, with an arrow between them.
2. Paint your leather-cut background over the placeholder, keeping the two dashed
   zones visually clear (the real icons render on top of them).
3. Export it as **`background.png`** (this folder), at **600 × 400 px**.

That's it. `scripts/package_app.sh` automatically detects `background.png` and
builds the styled, positioned DMG. If `background.png` is absent, it falls back
to a plain (un-styled) drag-install DMG, so packaging never breaks.

## Layout reference

| Item            | Icon center (pt) | Icon size |
|-----------------|------------------|-----------|
| Window content  | 600 × 400        | —         |
| Pathstitch.app  | (150, 190)       | 100       |
| Applications    | (450, 190)       | 100       |

Coordinates are in the window's content area, origin top-left — the same space
the Finder AppleScript in `package_app.sh` uses, so the art and the icons stay
aligned. To change the layout, edit the matching constants in `package_app.sh`
**and** this template together.
