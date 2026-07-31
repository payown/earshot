#!/usr/bin/env python3
"""Generate the Earshot app icon: ear + sound waves on deep teal background.
Draws at 2x resolution then downsamples for anti-aliasing.
Output: assets/icon/icon.png (1024x1024, RGB)
"""
from PIL import Image, ImageDraw

SIZE = 1024
SCALE = 2
S = SIZE * SCALE

BG_COLOR = '#0B7A8C'   # deep teal
FG_COLOR = (255, 255, 255, 255)  # white

img = Image.new('RGBA', (S, S), (0, 0, 0, 0))
draw = ImageDraw.Draw(img)

# --- Background: solid rounded square ---
RADIUS = 230 * SCALE
draw.rounded_rectangle([0, 0, S - 1, S - 1], radius=RADIUS, fill=BG_COLOR)

# --- Ear shape ---
# Positioned slightly left of center to leave room for sound waves.
# All coordinates at 2x scale.
EX = 370 * SCALE   # ear center x
EY = 512 * SCALE   # ear center y (vertically centred)

# Outer ear ellipse (white)
OW, OH = 200 * SCALE, 400 * SCALE
draw.ellipse([EX - OW // 2, EY - OH // 2, EX + OW // 2, EY + OH // 2], fill=FG_COLOR)

# Inner ear concha (teal cutout), offset slightly toward sound waves
IW, IH = 110 * SCALE, 265 * SCALE
IX_OFF = 14 * SCALE
draw.ellipse(
    [EX - IW // 2 + IX_OFF, EY - IH // 2, EX + IW // 2 + IX_OFF, EY + IH // 2],
    fill=BG_COLOR,
)

# Ear canal: small white circle
CR = 36 * SCALE
draw.ellipse(
    [EX - CR + IX_OFF, EY - CR, EX + CR + IX_OFF, EY + CR],
    fill=FG_COLOR,
)

# --- Sound waves: three arcs radiating right from the ear ---
# PIL arc: 0° = right, 90° = down (clockwise). Arcs centred on the ear.
WAVE_START = -58   # degrees above horizontal
WAVE_END   =  58   # degrees below horizontal

waves = [
    (240 * SCALE, 44 * SCALE, 255),   # inner
    (330 * SCALE, 38 * SCALE, 255),   # middle
    (420 * SCALE, 32 * SCALE, 255),   # outer
]

for radius, width, alpha in waves:
    bbox = [EX - radius, EY - radius, EX + radius, EY + radius]
    draw.arc(bbox, start=WAVE_START, end=WAVE_END,
             fill=(255, 255, 255, alpha), width=width)

# --- Downsample to 1024×1024 (anti-aliasing) ---
img = img.resize((SIZE, SIZE), Image.LANCZOS)

# Flatten onto solid teal background (iOS icons must not have alpha)
bg = Image.new('RGB', (SIZE, SIZE), BG_COLOR)
bg.paste(img, mask=img.split()[3])
bg.save('assets/icon/icon.png', 'PNG')
print('Saved assets/icon/icon.png')
