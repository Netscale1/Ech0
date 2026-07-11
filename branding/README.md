# Ech0 branding assets

The v2 set uses one Imagegen source and a deterministic Python finishing pipeline.

## Source and masters

- `sources/ech0-active-imagegen.png`: high-resolution generative source.
- `v2/masters/ech0-mark-active-2048.png`: symmetric transparent active master.
- `v2/masters/ech0-mark-idle-2048.png`: matching idle master without the central activity motif.

Run `python3 scripts/build-brand-assets.py`, followed by:

```sh
iconutil -c icns branding/v2/macos/Ech0.iconset -o macos/Resources/Ech0.icns
```

The build produces:

- macOS UI marks at the exact 30, 38, and 70 pt sizes in 1x/2x, plus 1024 px fallbacks;
- macOS menu-bar templates at 18 px and 36 px;
- a complete macOS `.iconset` and app icon;
- Windows application and tray `.ico` files with 16, 20, 24, 32, 48, 64, 128, and 256 px frames;
- `qa/ech0-brand-contact-sheet.png` and a machine-readable validation report.

## State palette

- Disconnected: `#7A7A80`
- Waiting: `#0A84FF`
- Unavailable: `#F5A623`
- Capturing: `#F20C7A`

macOS template images remain monochrome so the system can adapt them to light and dark menu bars.
