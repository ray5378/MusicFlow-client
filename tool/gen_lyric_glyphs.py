# -*- coding: utf-8 -*-
"""Extract remixicon glyph outlines as GDI+ path data (desktop lyric window).

Why offline extraction: the native lyric window cannot load remix.ttf at
runtime.  AddFontResourceExW(FR_PRIVATE) is invisible to GDI+ FontFamily
(status 14), and PrivateFontCollection crashes (c0000005 in gdiplus.dll
10.0.19041) the first time its family enters GraphicsPath::AddString.
So the glyphs the window needs are extracted once and hardcoded as
point/type arrays in windows/runner/desktop_lyric.cpp.

Usage:
  gen_lyric_glyphs.py                # print C++ snippet to stdout
  gen_lyric_glyphs.py --patch PATH   # rewrite the data section in the cpp
  gen_lyric_glyphs.py [font.ttf]     # optional font override

Conversion notes:
- TrueType quadratics (qCurveTo chains with implied on-curve midpoints) are
  elevated to cubic beziers: c1 = p0 + 2/3 (c - p0), c2 = p2 + 2/3 (c - p2).
- Y axis is flipped (y -> -y) to match GDI+ default top-down space.
- Types use PathPointType Start=0 / Line=1 / Bezier=3 with the CloseSubpath
  flag (0x80) on the last point of each contour.
- All numeric literals carry the f suffix: the runner target compiles with
  /WX, and double->float narrowing (C4305) would fail the build.
"""
import re
import sys

from fontTools.ttLib import TTFont
from fontTools.pens.recordingPen import RecordingPen

_args = [a for a in sys.argv[1:] if not a.startswith("--")]
FONT_DEFAULT = ("C:/Users/ray5378/AppData/Local/Pub/Cache/hosted/pub.dev/"
                "remixicon-4.9.3/fonts/remix.ttf")

GLYPHS = [
    (0xF00D, "Queue", "play_list_2_line"),
    (0xF399, "Order", "list_ordered_2"),
]

START_MARK = "// ---- 硬编码 remixicon 字形轮廓(由 tool/gen_lyric_glyphs.py 生成"
END_MARK = "// ---- end glyph data ----"


def ops_to_subpaths(ops):
    """RecordingPen ops -> list of contours.

    Each contour: {"start": (x, y), "segs": [("L", p) | ("C", c1, c2, p)]}.
    """
    subs, cur, start, sub = [], None, None, None
    for op, args in ops:
        if op == "moveTo":
            sub = {"start": args[0], "segs": []}
            cur, start = args[0], args[0]
        elif op == "lineTo":
            sub["segs"].append(("L", args[0]))
            cur = args[0]
        elif op == "qCurveTo":
            pts = list(args)
            if pts and pts[-1] is None:
                pts[-1] = start  # implied on-point wraps to contour start
            offs, on = pts[:-1], pts[-1]
            prev = cur
            for i, o in enumerate(offs):
                if i == len(offs) - 1:
                    nxt = on
                else:  # implied on-curve midpoint between two off-points
                    nxt = ((o[0] + offs[i + 1][0]) / 2.0,
                           (o[1] + offs[i + 1][1]) / 2.0)
                c1 = (prev[0] + (o[0] - prev[0]) * 2.0 / 3.0,
                      prev[1] + (o[1] - prev[1]) * 2.0 / 3.0)
                c2 = (nxt[0] + (o[0] - nxt[0]) * 2.0 / 3.0,
                      nxt[1] + (o[1] - nxt[1]) * 2.0 / 3.0)
                sub["segs"].append(("C", c1, c2, nxt))
                prev = nxt
            cur = on
        elif op == "curveTo":
            c1, c2, p = args
            sub["segs"].append(("C", c1, c2, p))
            cur = p
        elif op == "closePath":
            if sub is not None:
                subs.append(sub)
                sub = None
        else:
            raise ValueError("unexpected pen op: %s" % op)
    if sub is not None:
        subs.append(sub)
    return subs


def fmt(v):
    r = round(v, 2)
    # 统一带 f 后缀:runner 目标开 /WX,double 字面量赋 float 会 C4305 当错。
    # 注意 int 后不能直接拼 f(1100f 非法),要 1100.0f。
    if abs(r - round(r)) < 1e-9:
        return "%d.0f" % round(r)
    return ("%.2f" % r).rstrip("0").rstrip(".") + "f"


def build_block(font):
    upm = font["head"].unitsPerEm
    cmap = font.getBestCmap()
    glyphset = font.getGlyphSet()
    out = ["// ---- 硬编码 remixicon 字形轮廓(由 tool/gen_lyric_glyphs.py 生成,"
           " upm=%d, Y 已翻转为向下为正) ----" % upm]
    for cp, ident, gname in GLYPHS:
        name = cmap[cp]
        pen = RecordingPen()
        glyphset[name].draw(pen)
        ops_summary = {}
        for op, _ in pen.value:
            ops_summary[op] = ops_summary.get(op, 0) + 1
        subs = ops_to_subpaths(pen.value)
        pts, types = [], []
        for s in subs:
            pts.append((s["start"][0], -s["start"][1]))
            types.append(0x00)  # PathPointTypeStart
            for seg in s["segs"]:
                if seg[0] == "L":
                    pts.append((seg[1][0], -seg[1][1]))
                    types.append(0x01)  # PathPointTypeLine
                else:
                    _, c1, c2, p = seg
                    for q in (c1, c2, p):
                        pts.append((q[0], -q[1]))
                        types.append(0x03)  # PathPointTypeBezier
            types[-1] |= 0x80  # CloseSubpath flag
        xs = [p[0] for p in pts]
        ys = [p[1] for p in pts]
        out.append("// U+%04X %s (%s): %d contours, %d points, ink bbox "
                   "x[%d..%d] y[%d..%d]" % (
                       cp, gname, name, len(subs), len(pts),
                       min(xs), max(xs), min(ys), max(ys)))
        out.append("static const GlyphPt kRemix%sPts[] = {" % ident)
        line = "   "
        for x, y in pts:
            piece = " {%s,%s}," % (fmt(x), fmt(y))
            if len(line) + len(piece) > 96:
                out.append(line)
                line = "   "
            line += piece
        if line.strip():
            out.append(line)
        out.append("};")
        out.append("static const BYTE kRemix%sTypes[] = {" % ident)
        line = "   "
        for t in types:
            piece = " 0x%02X," % t
            if len(line) + len(piece) > 96:
                out.append(line)
                line = "   "
            line += piece
        if line.strip():
            out.append(line)
        out.append("};")
        out.append("static const RemixGlyphDef kRemix%s{" % ident)
        out.append("    kRemix%sPts, kRemix%sTypes, %d};" % (
            ident, ident, len(pts)))
        out.append("// ops: %s" % ops_summary)
    out.append(END_MARK)
    return "\n".join(out)


def main():
    font_path, cpp = FONT_DEFAULT, None
    argv, i = sys.argv[1:], 0
    while i < len(argv):
        if argv[i] == "--patch":
            cpp = argv[i + 1]
            i += 2
        elif argv[i].startswith("--"):
            i += 1
        else:
            font_path = argv[i]
            i += 1
    font = TTFont(font_path)
    block = build_block(font)
    if cpp:
        with open(cpp, "r", encoding="utf-8", newline="") as f:
            content = f.read()
        pattern = re.escape(START_MARK) + r".*?" + re.escape(END_MARK)
        new_content, n = re.subn(pattern, lambda _: block, content,
                                 count=1, flags=re.S)
        if n != 1:
            raise SystemExit("patch target section not found in " + cpp)
        with open(cpp, "w", encoding="utf-8", newline="") as f:
            f.write(new_content)
        print("patched %s" % cpp)
    else:
        print(block)


if __name__ == "__main__":
    main()
