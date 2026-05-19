#!/usr/bin/env python3
"""Resize assets/icon/icon.png into all required iOS and Android icon sizes."""
import json
import os
from PIL import Image

SRC = 'assets/icon/icon.png'
src = Image.open(SRC).convert('RGB')

def save(path, size):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    src.resize((size, size), Image.LANCZOS).save(path, 'PNG')
    print(f'  {path} ({size}x{size})')

# ── iOS ──────────────────────────────────────────────────────────────────────
IOS_DIR = 'ios/Runner/Assets.xcassets/AppIcon.appiconset'

ios_sizes = [
    ('Icon-App-20x20@1x.png',    20),
    ('Icon-App-20x20@2x.png',    40),
    ('Icon-App-20x20@3x.png',    60),
    ('Icon-App-29x29@1x.png',    29),
    ('Icon-App-29x29@2x.png',    58),
    ('Icon-App-29x29@3x.png',    87),
    ('Icon-App-40x40@1x.png',    40),
    ('Icon-App-40x40@2x.png',    80),
    ('Icon-App-40x40@3x.png',   120),
    ('Icon-App-60x60@2x.png',   120),
    ('Icon-App-60x60@3x.png',   180),
    ('Icon-App-76x76@1x.png',    76),
    ('Icon-App-76x76@2x.png',   152),
    ('Icon-App-83.5x83.5@2x.png', 167),
    ('Icon-App-1024x1024@1x.png', 1024),
]

print('iOS:')
for name, size in ios_sizes:
    save(f'{IOS_DIR}/{name}', size)

# Write Contents.json
contents = {
    "images": [
        {"size": "20x20",       "idiom": "iphone",      "filename": "Icon-App-20x20@2x.png",       "scale": "2x"},
        {"size": "20x20",       "idiom": "iphone",      "filename": "Icon-App-20x20@3x.png",       "scale": "3x"},
        {"size": "29x29",       "idiom": "iphone",      "filename": "Icon-App-29x29@1x.png",       "scale": "1x"},
        {"size": "29x29",       "idiom": "iphone",      "filename": "Icon-App-29x29@2x.png",       "scale": "2x"},
        {"size": "29x29",       "idiom": "iphone",      "filename": "Icon-App-29x29@3x.png",       "scale": "3x"},
        {"size": "40x40",       "idiom": "iphone",      "filename": "Icon-App-40x40@2x.png",       "scale": "2x"},
        {"size": "40x40",       "idiom": "iphone",      "filename": "Icon-App-40x40@3x.png",       "scale": "3x"},
        {"size": "60x60",       "idiom": "iphone",      "filename": "Icon-App-60x60@2x.png",       "scale": "2x"},
        {"size": "60x60",       "idiom": "iphone",      "filename": "Icon-App-60x60@3x.png",       "scale": "3x"},
        {"size": "20x20",       "idiom": "ipad",        "filename": "Icon-App-20x20@1x.png",       "scale": "1x"},
        {"size": "20x20",       "idiom": "ipad",        "filename": "Icon-App-20x20@2x.png",       "scale": "2x"},
        {"size": "29x29",       "idiom": "ipad",        "filename": "Icon-App-29x29@1x.png",       "scale": "1x"},
        {"size": "29x29",       "idiom": "ipad",        "filename": "Icon-App-29x29@2x.png",       "scale": "2x"},
        {"size": "40x40",       "idiom": "ipad",        "filename": "Icon-App-40x40@1x.png",       "scale": "1x"},
        {"size": "40x40",       "idiom": "ipad",        "filename": "Icon-App-40x40@2x.png",       "scale": "2x"},
        {"size": "76x76",       "idiom": "ipad",        "filename": "Icon-App-76x76@1x.png",       "scale": "1x"},
        {"size": "76x76",       "idiom": "ipad",        "filename": "Icon-App-76x76@2x.png",       "scale": "2x"},
        {"size": "83.5x83.5",   "idiom": "ipad",        "filename": "Icon-App-83.5x83.5@2x.png",  "scale": "2x"},
        {"size": "1024x1024",   "idiom": "ios-marketing","filename": "Icon-App-1024x1024@1x.png",  "scale": "1x"},
    ],
    "info": {"version": 1, "author": "xcode"}
}
with open(f'{IOS_DIR}/Contents.json', 'w') as f:
    json.dump(contents, f, indent=2)
print(f'  {IOS_DIR}/Contents.json')

# ── Android ───────────────────────────────────────────────────────────────────
print('\nAndroid:')
android_sizes = [
    ('android/app/src/main/res/mipmap-mdpi/ic_launcher.png',     48),
    ('android/app/src/main/res/mipmap-hdpi/ic_launcher.png',     72),
    ('android/app/src/main/res/mipmap-xhdpi/ic_launcher.png',    96),
    ('android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png',  144),
    ('android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png', 192),
]
for path, size in android_sizes:
    save(path, size)

print('\nDone.')
