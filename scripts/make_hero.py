"""Compose the README hero (docs/hero.jpg): Verbatim's windows on a blurred
retro-tech desktop, from the PNGs that `--snapshot` writes (rendered at 2x).
Usage: python3 scripts/make_hero.py docs/screenshots docs/hero.jpg
Needs Pillow, NumPy and the Inter and JetBrains Mono fonts (paths below)."""
import sys, math, random
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

SRC, OUT = sys.argv[1], sys.argv[2]
ASSET_SCALE = float(sys.argv[3]) if len(sys.argv) > 3 else 2.0  # px per point in the PNGs
S = 2  # canvas px per point

W, H = 1600 * S, 1000 * S
SCREEN = (50 * S, 44 * S, 1550 * S, 900 * S)  # x0 y0 x1 y1
FONT = "/usr/share/fonts/opentype/inter/Inter-%s.otf"
MONO = "/usr/share/fonts/truetype/jetbrains-mono/JetBrainsMono-%s.ttf"


def font(weight, size, mono=False):
    return ImageFont.truetype((MONO if mono else FONT) % weight, int(size * S))


def asset(name, scale=1.0):
    im = Image.open(f"{SRC}/{name}.png").convert("RGBA")
    f = S / ASSET_SCALE * scale
    if f != 1:
        im = im.resize((round(im.width * f), round(im.height * f)), Image.LANCZOS)
    return im


def rounded(im, r):
    mask = Image.new("L", im.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, im.width - 1, im.height - 1), r, fill=255)
    out = im.copy()
    out.putalpha(Image.fromarray(np.minimum(np.array(im.getchannel("A")), np.array(mask))))
    return out


def shadow(canvas, im, xy, blur=28, offset=18, opacity=150):
    a = im.getchannel("A")
    pad = blur * 3
    sh = Image.new("RGBA", (im.width + pad * 2, im.height + pad * 2), (0, 0, 0, 0))
    sh.paste((0, 0, 0, opacity), (pad, pad), a)
    sh = sh.filter(ImageFilter.GaussianBlur(blur))
    canvas.alpha_composite(sh, (xy[0] - pad, xy[1] - pad + offset))


def outline(im, r, color=(255, 255, 255, 38)):
    d = ImageDraw.Draw(im)
    d.rounded_rectangle((0, 0, im.width - 1, im.height - 1), r, outline=color, width=max(1, S // 2 + 1))
    return im


def wallpaper(w, h):
    """Synthwave sunset: gradient sky, striped sun, perspective grid; then blurred."""
    y = np.linspace(0, 1, h)[:, None]
    stops = [(0.0, (34, 20, 84)), (0.30, (92, 36, 140)), (0.52, (206, 64, 140)),
             (0.68, (250, 128, 86)), (0.74, (255, 190, 110)), (0.76, (46, 16, 70)), (1.0, (18, 8, 40))]
    img = np.zeros((h, w, 3))
    for (p0, c0), (p1, c1) in zip(stops, stops[1:]):
        m = (y >= p0) & (y <= p1)
        t = np.clip((y - p0) / max(p1 - p0, 1e-6), 0, 1)
        for k in range(3):
            img[..., k] = np.where(m, c0[k] + (c1[k] - c0[k]) * t, img[..., k])
    im = Image.fromarray(img.astype(np.uint8)).convert("RGBA")
    d = ImageDraw.Draw(im)
    horizon = int(h * 0.75)
    # Sun with retro stripes, offset to the right so it peeks between windows.
    cx, r = int(w * 0.80), int(h * 0.24)
    sun = Image.new("RGBA", (2 * r, 2 * r), (0, 0, 0, 0))
    sd = ImageDraw.Draw(sun)
    for i in range(2 * r):
        t = i / (2 * r)
        col = (255, int(226 - 120 * t), int(110 + 40 * t), 255)
        half = int(math.sqrt(max(r * r - (r - i) ** 2, 0)))
        stripe = t > 0.5 and int((t - 0.5) * 40) % 2 == 1 and ((t - 0.5) * 40) % 1 < 0.35 + (t - 0.5)
        if not stripe:
            sd.line((r - half, i, r + half, i), fill=col)
    im.alpha_composite(sun, (cx - r, horizon - int(r * 1.35)))
    d.rectangle((0, horizon, w, h), fill=(26, 10, 52, 255))
    # Perspective grid.
    grid = (255, 96, 200, 255)
    for i in range(1, 22):
        t = (i / 22) ** 2.2
        yy = horizon + int((h - horizon) * t)
        d.line((0, yy, w, yy), fill=grid, width=max(2, int(4 * t * S)))
    vx = cx
    for k in range(-30, 31):
        d.line((vx, horizon, vx + k * w // 9, h), fill=grid, width=2 * S)
    # Distant mountains in silhouette.
    pts, x = [(0, horizon)], 0
    random.seed(7)
    while x < w:
        x += random.randint(60, 160) * S // 2
        pts.append((x, horizon - random.randint(10, 70) * S))
    pts.append((w, horizon))
    d.polygon(pts, fill=(34, 12, 58, 255))
    im = im.filter(ImageFilter.GaussianBlur(11 * S))
    # Film grain keeps the blur from looking flat.
    arr = np.array(im).astype(np.int16)
    noise = np.random.default_rng(3).normal(0, 6, arr.shape[:2])[..., None]
    arr[..., :3] = np.clip(arr[..., :3] + noise, 0, 255)
    return Image.fromarray(arr.astype(np.uint8))


canvas = Image.new("RGBA", (W, H), (12, 12, 14, 255))
d = ImageDraw.Draw(canvas)

# Faint "data" texture on the outer frame, a nod to old terminals.
mono = font("Regular", 9, mono=True)
random.seed(11)
for row_y in (8 * S, H - 24 * S):
    x = 12 * S
    while x < W - 20 * S:
        ch = random.choice("01·:*+.01 ")
        d.text((x, row_y), ch, font=mono, fill=(70, 70, 76, 255))
        x += 14 * S

# Laptop-like frame.
x0, y0, x1, y1 = SCREEN
d.rounded_rectangle((x0 - 18 * S, y0 - 18 * S, x1 + 18 * S, y1 + 18 * S), 34 * S, fill=(26, 26, 29, 255),
                    outline=(52, 52, 58, 255), width=S)
screen = wallpaper(x1 - x0, y1 - y0)
sd = ImageDraw.Draw(screen)
sw, sh_ = screen.size

# macOS-style menu bar.
bar_h = 30 * S
bar = Image.new("RGBA", (sw, bar_h), (20, 12, 40, 96))
screen.alpha_composite(bar, (0, 0))
menu_font, bold = font("Regular", 13.5), font("SemiBold", 13.5)
x = 22 * S
sd.text((x, bar_h // 2), "Verbatim", font=bold, fill=(255, 255, 255, 240), anchor="lm")
x += int(bold.getlength("Verbatim")) + 22 * S
for item in ("File", "Edit", "Window", "Help"):
    sd.text((x, bar_h // 2), item, font=menu_font, fill=(255, 255, 255, 220), anchor="lm")
    x += int(menu_font.getlength(item)) + 22 * S
clock = "Wed 2:43 PM"
cx_ = sw - 22 * S - int(menu_font.getlength(clock))
sd.text((cx_, bar_h // 2), clock, font=menu_font, fill=(255, 255, 255, 235), anchor="lm")
# Status item: Verbatim's three bars, highlighted because its window is open.
status_x = cx_ - 92 * S
sd.rounded_rectangle((status_x - 9 * S, 4 * S, status_x + 21 * S, bar_h - 4 * S), 6 * S, fill=(255, 255, 255, 60))
for i, hh in enumerate((8, 14, 10)):
    bx = status_x + i * 5 * S
    sd.rounded_rectangle((bx, bar_h // 2 - hh * S // 2, bx + 2 * S, bar_h // 2 + hh * S // 2), S, fill=(255, 255, 255, 245))
# A few neutral status icons for realism: battery and wifi-ish dots.
bx = status_x + 40 * S
sd.rounded_rectangle((bx, bar_h // 2 - 5 * S, bx + 22 * S, bar_h // 2 + 5 * S), 3 * S, outline=(255, 255, 255, 220), width=S)
sd.rectangle((bx + 2 * S, bar_h // 2 - 3 * S, bx + 16 * S, bar_h // 2 + 3 * S), fill=(255, 255, 255, 220))

# Main window.
main = outline(rounded(asset("verbatim-dark"), 12 * S), 12 * S)
mx, my = 70 * S, 82 * S
shadow(screen, main, (mx, my), blur=34 * S // 2, offset=20 * S, opacity=170)
screen.alpha_composite(main, (mx, my))

# Menu bar window, hanging from the status item.
menu = outline(rounded(asset("menubar-idle-dark"), 12 * S), 12 * S)
px = min(status_x + 6 * S - menu.width // 2, sw - menu.width - 14 * S)
py = bar_h + 6 * S
shadow(screen, menu, (px, py), blur=24 * S // 2, offset=14 * S, opacity=180)
screen.alpha_composite(menu, (px, py))

# Capsule, floating at the right edge, scaled up a little to read at README size.
cap = asset("panel-dark", 1.6)
# The PNG carries two thin window-edge bars above and below the capsule; drop them.
ca = np.array(cap)
top, bottom = int(cap.height * 14 / 304), int(cap.height * 290 / 304)
ca[:top, :, 3] = 0
ca[bottom:, :, 3] = 0
cap = Image.fromarray(ca)
kx, ky = sw - cap.width - 48 * S, py + menu.height + 70 * S
shadow(screen, cap, (kx, ky), blur=16 * S // 2, offset=10 * S, opacity=170)
screen.alpha_composite(cap, (kx, ky))

# Small captions pointing at the capsule and the menu bar window.
cap_font = font("Medium", 13)
def caption(text, x, y, anchor):
    tw = cap_font.getlength(text)
    pad = 10 * S
    bx0 = x - (tw + pad * 2) if anchor == "r" else x
    sd.rounded_rectangle((bx0, y - 14 * S, bx0 + tw + pad * 2, y + 14 * S), 14 * S, fill=(0, 0, 0, 120),
                         outline=(255, 255, 255, 50), width=S)
    sd.text((bx0 + pad, y), text, font=cap_font, fill=(255, 255, 255, 235), anchor="lm")
caption("Recording capsule", kx - 16 * S, ky + cap.height // 2, "r")

# Round the screen corners and place it.
screen = rounded(screen, 22 * S)
canvas.alpha_composite(screen, (x0, y0))

# Bottom pills, like a product tour.
pill_font = font("Medium", 17)
labels = [("Record", True), ("Transcribe", False), ("Know who", False), ("Export", False)]
gap = 14 * S
widths = [int(pill_font.getlength(t)) + 64 * S for t, _ in labels]
total = sum(widths) + gap * (len(widths) - 1)
x = (W - total) // 2
yc = (y1 + 18 * S + H) // 2
for (text, active), w_ in zip(labels, widths):
    box = (x, yc - 23 * S, x + w_, yc + 23 * S)
    if active:
        d.rounded_rectangle(box, 12 * S, fill=(58, 30, 22, 255), outline=(238, 112, 78, 255), width=2 * S)
        d.ellipse((x + 22 * S, yc - 5 * S, x + 32 * S, yc + 5 * S), fill=(240, 72, 72, 255))
        d.text((x + 42 * S, yc), text, font=pill_font, fill=(255, 255, 255, 255), anchor="lm")
    else:
        d.rounded_rectangle(box, 12 * S, fill=(24, 24, 27, 255), outline=(60, 60, 66, 255), width=S)
        d.text((x + w_ // 2, yc), text, font=pill_font, fill=(170, 170, 176, 255), anchor="mm")
    x += w_ + gap

rgb = canvas.convert("RGB")
rgb.save(OUT, quality=90, optimize=True, progressive=True) if OUT.endswith(".jpg") else rgb.save(OUT, optimize=True)
print(OUT, canvas.size)
