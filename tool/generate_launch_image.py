#!/usr/bin/env python3
"""Generate launch screen images: centered icon on solid teal background.
Outputs the three LaunchImage sizes for iOS.
"""
from PIL import Image

BG = '#0B7A8C'
ICON_SRC = 'assets/icon/icon.png'
OUT_DIR = 'ios/Runner/Assets.xcassets/LaunchImage.imageset'

icon = Image.open(ICON_SRC).convert('RGBA')

sizes = [
    ('LaunchImage.png',    320, 80),
    ('LaunchImage@2x.png', 640, 160),
    ('LaunchImage@3x.png', 960, 240),
]

for filename, canvas_size, icon_size in sizes:
    bg = Image.new('RGB', (canvas_size, canvas_size), BG)
    thumb = icon.resize((icon_size, icon_size), Image.LANCZOS)
    x = (canvas_size - icon_size) // 2
    y = (canvas_size - icon_size) // 2
    bg.paste(thumb, (x, y), mask=thumb.split()[3])
    path = f'{OUT_DIR}/{filename}'
    bg.save(path, 'PNG')
    print(f'  {path} ({canvas_size}x{canvas_size}, icon {icon_size}px)')

print('Done.')
