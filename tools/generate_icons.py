#!/usr/bin/env python3
"""MusicFlow 品牌图标统一生成器。

输入：用户提供的新 logo 源图（1920x1920 jpg，黑底 + 红色实心圆 + 白色音符）。
输出：客户端全部平台图标 + 可直接复制到其他仓库的成品 PNG。

用法：
    python tools/generate_icons.py <源图路径>
"""
import os
import re
import sys

from PIL import Image

SRC = sys.argv[1] if len(sys.argv) > 1 else None
if not SRC or not os.path.isfile(SRC):
    sys.exit("usage: python tools/generate_icons.py <source image path>")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSET_DIR = os.path.join(ROOT, "assets", "icon")
WEB_DIR = os.path.join(ROOT, "web")
ANDROID_RES = os.path.join(ROOT, "android", "app", "src", "main", "res")
IOS_APPICON = os.path.join(
    ROOT, "ios", "Runner", "Assets.xcassets", "AppIcon.appiconset"
)
IOS_LAUNCH = os.path.join(
    ROOT, "ios", "Runner", "Assets.xcassets", "LaunchImage.imageset"
)
WIN_RUNNER = os.path.join(ROOT, "windows", "runner", "resources")

BRAND_RED = (230, 0, 18)  # 品牌红（Apple-Music 风格纯红，用于颜色归一化）


def is_red(px):
    r, g, b = px
    return r > 110 and g < 90 and b < 90


def is_blackish(px):
    r, g, b = px
    return r < 40 and g < 40 and b < 40


def find_content_bbox(im):
    """求红色圆环 ∪ 白色音符 的联合包围盒（音符头会伸出圆外，必须包含）。"""
    w, h = im.size
    minx, miny, maxx, maxy = w, h, 0, 0
    step = 2
    for y in range(0, h, step):
        for x in range(0, w, step):
            r, g, b = im.getpixel((x, y))
            if is_red((r, g, b)) or (r > 200 and g > 200 and b > 200):
                minx = min(minx, x)
                maxx = max(maxx, x)
                miny = min(miny, y)
                maxy = max(maxy, y)
    if maxx <= minx:
        raise RuntimeError("icon content not found in source image")
    return minx, miny, maxx, maxy


def crop_master(im, bbox, content_ratio=0.80):
    """以全部内容中心裁出方形母版，内容占画布 content_ratio（每边留 (1-ratio)/2 边距）。"""
    minx, miny, maxx, maxy = bbox
    cx = (minx + maxx) // 2
    cy = (miny + maxy) // 2
    span = max(maxx - minx, maxy - miny)
    d = int(span / content_ratio) + 1
    half = d // 2
    left = cx - half
    top = cy - half
    box = (max(0, left), max(0, top), min(im.size[0], left + d), min(im.size[1], top + d))
    return im.crop(box)


def make_black_master(crop, size=1024):
    """黑底母版：背景压成纯黑，保留主体与抗锯齿。"""
    img = crop.convert("RGB")
    px = img.load()
    w, h = img.size
    for y in range(h):
        for x in range(w):
            p = px[x, y]
            if is_blackish(p):
                px[x, y] = (0, 0, 0)
    return img.resize((size, size), Image.LANCZOS)


def make_transparent_master(crop, size=1024):
    """透明底母版：黑色背景 -> 透明（红圆+白音符自包含）。"""
    img = crop.convert("RGBA")
    px = img.load()
    w, h = img.size
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if r < 40 and g < 40 and b < 40:
                px[x, y] = (0, 0, 0, 0)
    return img.resize((size, size), Image.LANCZOS)


def paste_centered(canvas, logo, content_ratio):
    """把 logo 按 content_ratio 缩放后居中贴到画布。RGB 画布无 mask，RGBA 用自身 alpha。"""
    cw, ch = canvas.size
    target = int(min(cw, ch) * content_ratio)
    scaled = logo.resize((target, target), Image.LANCZOS)
    if canvas.mode == "RGBA":
        canvas.paste(scaled, ((cw - target) // 2, (ch - target) // 2), scaled)
    else:
        canvas.paste(scaled, ((cw - target) // 2, (ch - target) // 2))
    return canvas


def save_png(img, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path, "PNG")
    print("  ->", os.path.relpath(path, ROOT), img.size, img.mode)


def main():
    print("== 1/4 解析源图，生成母版 ==")
    src = Image.open(SRC).convert("RGB")
    bbox = find_content_bbox(src)
    print("content bbox:", bbox, "size:", bbox[2] - bbox[0], bbox[3] - bbox[1])
    crop = crop_master(src, bbox, content_ratio=0.80)

    black = make_black_master(crop)
    transp = make_transparent_master(crop)

    os.makedirs(ASSET_DIR, exist_ok=True)
    black.save(os.path.join(ASSET_DIR, "app_icon_black.png"), "PNG")
    transp.save(os.path.join(ASSET_DIR, "app_icon.png"), "PNG")
    print("  -> assets/icon/app_icon.png (透明底母版)")
    print("  -> assets/icon/app_icon_black.png (黑底母版)")

    print("== 2/4 Web / PWA ==")
    # 品牌规范：一律黑底版（与源图黑底一致），favicon/Icon 均保留黑色背景
    save_png(black.resize((32, 32), Image.LANCZOS), os.path.join(WEB_DIR, "favicon.png"))
    save_png(black.resize((192, 192), Image.LANCZOS), os.path.join(WEB_DIR, "icons", "Icon-192.png"))
    save_png(black.resize((512, 512), Image.LANCZOS), os.path.join(WEB_DIR, "icons", "Icon-512.png"))
    # maskable：必须不透明满幅，内容留安全区
    for size in (192, 512):
        canvas = Image.new("RGB", (size, size), (0, 0, 0))
        paste_centered(canvas, transp, 0.80)
        save_png(canvas, os.path.join(WEB_DIR, "icons", f"Icon-maskable-{size}.png"))

    print("== 3/4 Android ==")
    # adaptive foreground：108dp 画布（用 432px），内容 66% 安全区
    for dpi, px in (("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)):
        # legacy 方形图标：黑底版（内容 82% 居中），系统自行裁圆角
        canvas = Image.new("RGB", (px, px), (0, 0, 0))
        paste_centered(canvas, black, 0.82)
        save_png(canvas, os.path.join(ANDROID_RES, f"mipmap-{dpi}", "ic_launcher.png"))
        # adaptive foreground：透明画布，内容 66%（108dp 画布换算）
        # 背景纯黑由 mipmap-anydpi-v26/ic_launcher.xml 提供，合成后同样黑底红圆
        fg = px * 3  # 108dp * density 的近似（4x 采样画布）
        fg_canvas = Image.new("RGBA", (fg, fg), (0, 0, 0, 0))
        paste_centered(fg_canvas, transp, 0.66)
        save_png(
            fg_canvas.resize((px, px), Image.LANCZOS),
            os.path.join(ANDROID_RES, f"mipmap-{dpi}", "ic_launcher_foreground.png"),
        )

    print("== 4/4 iOS + Windows ==")
    # iOS AppIcon：黑底不透明，内容 82%（留圆角裁切安全边）
    names = sorted(os.listdir(IOS_APPICON))
    for name in names:
        m = re.match(r"Icon-App-(\d+(?:\.\d+)?)x\d+(?:\.\d+)?@(\d)x\.png", name)
        if not m:
            continue
        pt = float(m.group(1))
        scale = int(m.group(2))
        px = int(round(pt * scale))
        canvas = Image.new("RGB", (px, px), (0, 0, 0))
        paste_centered(canvas, black, 0.82)
        save_png(canvas, os.path.join(IOS_APPICON, name))
    # iOS 启动图：黑底
    for name in ("LaunchImage.png", "LaunchImage@2x.png", "LaunchImage@3x.png"):
        scale = {"LaunchImage.png": 1, "LaunchImage@2x.png": 2, "LaunchImage@3x.png": 3}[name]
        px = 375 * scale
        canvas = Image.new("RGB", (px, px), (0, 0, 0))
        paste_centered(canvas, black, 0.60)
        save_png(canvas, os.path.join(IOS_LAUNCH, name))
    # Windows ico：黑底版多尺寸
    ico_path = os.path.join(WIN_RUNNER, "app_icon.ico")
    os.makedirs(WIN_RUNNER, exist_ok=True)
    black.convert("RGBA").resize((256, 256), Image.LANCZOS).save(
        ico_path,
        format="ICO",
        sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)],
    )
    print("  -> windows/runner/resources/app_icon.ico")

    # 跨仓成品：180px apple-touch-icon（黑底）+ 1024 黑底大图（复制到主项目/HA 集成）
    save_png(black.resize((180, 180), Image.LANCZOS), os.path.join(ASSET_DIR, "apple-touch-icon.png"))
    save_png(black, os.path.join(ASSET_DIR, "app_icon_1024.png"))

    print("== 完成 ==")
    print("跨仓成品（复制用）:")
    print("  black 512:", os.path.join(ASSET_DIR, "app_icon_black.png"))
    print("  black 180:", os.path.join(ASSET_DIR, "apple-touch-icon.png"))
    print("  transparent 512（备用，仅 assets 留存）:", os.path.join(ASSET_DIR, "app_icon.png"))


if __name__ == "__main__":
    main()
