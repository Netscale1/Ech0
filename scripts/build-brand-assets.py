#!/usr/bin/env python3
"""Build the Ech0 v2 raster branding set from one high-resolution source."""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "branding" / "sources" / "ech0-active-imagegen.png"
BRAND = ROOT / "branding" / "v2"
MAC_RESOURCES = ROOT / "macos" / "Resources"
WINDOWS_RESOURCES = ROOT / "windows" / "Ech0Windows" / "Resources"
QA = ROOT / "branding" / "qa"

MASTER_SIZE = 2048
BRAND_MAGENTA = (242, 12, 122, 255)
STATE_COLORS = {
    "Disconnected": (122, 122, 128, 255),
    "Waiting": (10, 132, 255, 255),
    "Unavailable": (245, 166, 35, 255),
    "Capturing": (242, 12, 122, 255),
}


def foreground_mask(source: Image.Image) -> Image.Image:
    rgb = np.asarray(source.convert("RGB"), dtype=np.int16)
    red, green, blue = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    green_dominance = green - np.maximum(red, blue)
    mask = green_dominance < 100
    mask = np.logical_or(mask, np.fliplr(mask))

    ys, xs = np.nonzero(mask)
    if len(xs) == 0:
        raise RuntimeError("No foreground detected in the Imagegen source")

    cropped = Image.fromarray(mask[ys.min() : ys.max() + 1, xs.min() : xs.max() + 1].astype(np.uint8) * 255)
    target_extent = int(MASTER_SIZE * 0.80)
    scale = min(target_extent / cropped.width, target_extent / cropped.height)
    resized = cropped.resize(
        (round(cropped.width * scale), round(cropped.height * scale)),
        Image.Resampling.LANCZOS,
    )

    canvas = Image.new("L", (MASTER_SIZE, MASTER_SIZE), 0)
    canvas.paste(resized, ((MASTER_SIZE - resized.width) // 2, (MASTER_SIZE - resized.height) // 2))
    return canvas


def idle_mask(active: Image.Image) -> Image.Image:
    values = np.asarray(active, dtype=np.uint8).copy()
    x_offset = round(MASTER_SIZE * 0.34)
    y_start = round(MASTER_SIZE * 0.43)
    y_end = round(MASTER_SIZE * 0.57)
    values[y_start:y_end, x_offset : MASTER_SIZE - x_offset] = 0
    return Image.fromarray(values)


def rgba_mark(mask: Image.Image, color: tuple[int, int, int, int], size: int) -> Image.Image:
    alpha = mask.resize((size, size), Image.Resampling.LANCZOS)
    alpha_array = np.asarray(alpha, dtype=np.float32)
    alpha_array = np.clip((alpha_array - 20.0) * (255.0 / 215.0), 0, 255).astype(np.uint8)
    output = Image.new("RGBA", (size, size), color)
    output.putalpha(Image.fromarray(alpha_array))
    return output


def app_icon(active: Image.Image, size: int) -> Image.Image:
    icon = Image.new("RGBA", (size, size), BRAND_MAGENTA)
    mark = rgba_mark(active, (18, 18, 20, 255), round(size * 0.86))
    icon.alpha_composite(mark, ((size - mark.width) // 2, (size - mark.height) // 2))
    return icon


def save_mac_iconset(icon: Image.Image) -> None:
    iconset = BRAND / "macos" / "Ech0.iconset"
    iconset.mkdir(parents=True, exist_ok=True)
    for points in (16, 32, 128, 256, 512):
        icon.resize((points, points), Image.Resampling.LANCZOS).save(iconset / f"icon_{points}x{points}.png")
        doubled = points * 2
        icon.resize((doubled, doubled), Image.Resampling.LANCZOS).save(
            iconset / f"icon_{points}x{points}@2x.png"
        )


def save_windows_icon(path: Path, image: Image.Image) -> None:
    sizes = [(value, value) for value in (16, 20, 24, 32, 48, 64, 128, 256)]
    image.resize((256, 256), Image.Resampling.LANCZOS).save(path, format="ICO", sizes=sizes)


def checkerboard(size: tuple[int, int], cell: int = 12) -> Image.Image:
    image = Image.new("RGB", size, "white")
    draw = ImageDraw.Draw(image)
    for y in range(0, size[1], cell):
        for x in range(0, size[0], cell):
            if (x // cell + y // cell) % 2:
                draw.rectangle((x, y, x + cell - 1, y + cell - 1), fill=(232, 232, 234))
    return image


def build_contact_sheet(active: Image.Image, idle: Image.Image) -> Image.Image:
    sheet = Image.new("RGB", (1400, 900), (246, 246, 247))
    draw = ImageDraw.Draw(sheet)
    font = ImageFont.load_default(size=22)
    small_font = ImageFont.load_default(size=16)
    draw.text((52, 38), "Ech0 brand asset QA", fill=(24, 24, 26), font=font)

    for column, (label, mask) in enumerate((("ACTIVE", active), ("IDLE", idle))):
        x = 52 + column * 440
        draw.text((x, 92), label, fill=(92, 92, 98), font=small_font)
        panel = checkerboard((360, 360))
        panel.paste(rgba_mark(mask, (18, 18, 20, 255), 320), (20, 20), rgba_mark(mask, (18, 18, 20, 255), 320))
        sheet.paste(panel, (x, 122))

        cursor = x
        for size in (64, 32, 18):
            tile = Image.new("RGBA", (112, 112), (255, 255, 255, 255))
            mark = rgba_mark(mask, (18, 18, 20, 255), size)
            tile.alpha_composite(mark, ((112 - size) // 2, (112 - size) // 2))
            sheet.paste(tile.convert("RGB"), (cursor, 512))
            draw.text((cursor + 42, 632), f"{size}", fill=(92, 92, 98), font=small_font)
            cursor += 124

    draw.text((952, 92), "WINDOWS TRAY STATES", fill=(92, 92, 98), font=small_font)
    for row, (state, color) in enumerate(STATE_COLORS.items()):
        mask = active if state == "Capturing" else idle
        y = 126 + row * 132
        for bg_x, bg in ((952, (255, 255, 255, 255)), (1068, (35, 35, 38, 255))):
            tile = Image.new("RGBA", (96, 96), bg)
            mark = rgba_mark(mask, color, 48)
            tile.alpha_composite(mark, (24, 24))
            sheet.paste(tile.convert("RGB"), (bg_x, y))
        draw.text((1178, y + 38), state, fill=(24, 24, 26), font=small_font)

    icon = app_icon(active, 224)
    sheet.paste(icon.convert("RGB"), (952, 678))
    draw.text((1194, 770), "APP ICON", fill=(92, 92, 98), font=small_font)
    return sheet


def symmetry_error(mask: Image.Image) -> float:
    values = np.asarray(mask, dtype=np.int16)
    return float(np.abs(values - np.fliplr(values)).mean())


def main() -> None:
    if not SOURCE.exists():
        raise FileNotFoundError(SOURCE)

    for directory in (BRAND / "masters", BRAND / "macos", BRAND / "windows", MAC_RESOURCES, WINDOWS_RESOURCES, QA):
        directory.mkdir(parents=True, exist_ok=True)

    active = foreground_mask(Image.open(SOURCE))
    idle = idle_mask(active)
    active_master = rgba_mark(active, (0, 0, 0, 255), MASTER_SIZE)
    idle_master = rgba_mark(idle, (0, 0, 0, 255), MASTER_SIZE)
    active_master.save(BRAND / "masters" / "ech0-mark-active-2048.png")
    idle_master.save(BRAND / "masters" / "ech0-mark-idle-2048.png")

    rgba_mark(active, (0, 0, 0, 255), 1024).save(MAC_RESOURCES / "Ech0BrandActiveTemplate.png")
    rgba_mark(idle, (0, 0, 0, 255), 1024).save(MAC_RESOURCES / "Ech0BrandIdleTemplate.png")
    for state, mask in (("Active", active), ("Idle", idle)):
        for points in (30, 38, 70):
            rgba_mark(mask, (0, 0, 0, 255), points).save(
                MAC_RESOURCES / f"Ech0Brand{state}{points}Template.png"
            )
            rgba_mark(mask, (0, 0, 0, 255), points * 2).save(
                MAC_RESOURCES / f"Ech0Brand{state}{points}Template@2x.png"
            )
    for state, mask in (("Active", active), ("Idle", idle)):
        rgba_mark(mask, (0, 0, 0, 255), 18).save(MAC_RESOURCES / f"Ech0Status{state}Template.png")
        rgba_mark(mask, (0, 0, 0, 255), 36).save(MAC_RESOURCES / f"Ech0Status{state}Template@2x.png")

    mac_icon = app_icon(active, 1024)
    mac_icon.save(BRAND / "macos" / "Ech0AppIcon1024.png")
    save_mac_iconset(mac_icon)

    save_windows_icon(WINDOWS_RESOURCES / "Ech0App.ico", mac_icon)
    for state, color in STATE_COLORS.items():
        mask = active if state == "Capturing" else idle
        tray = rgba_mark(mask, color, 256)
        save_windows_icon(WINDOWS_RESOURCES / f"Ech0{state}.ico", tray)
        tray.save(BRAND / "windows" / f"Ech0{state}-256.png")

    sheet = build_contact_sheet(active, idle)
    sheet.save(QA / "ech0-brand-contact-sheet.png")

    report = {
        "source": str(SOURCE.relative_to(ROOT)),
        "masterSize": MASTER_SIZE,
        "activeSymmetryMeanError": round(symmetry_error(active), 6),
        "idleSymmetryMeanError": round(symmetry_error(idle), 6),
        "transparentCorners": all(active.getpixel(point) == 0 for point in ((0, 0), (0, MASTER_SIZE - 1), (MASTER_SIZE - 1, 0), (MASTER_SIZE - 1, MASTER_SIZE - 1))),
        "windowsIcoSizes": [16, 20, 24, 32, 48, 64, 128, 256],
        "palette": {key: "#%02X%02X%02X" % value[:3] for key, value in STATE_COLORS.items()},
    }
    (QA / "asset-report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
