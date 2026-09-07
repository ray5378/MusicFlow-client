#include "desktop_lyric.h"

#include <windowsx.h>

#include <algorithm>
#include <cmath>
#include <string>

// AlphaBlend(毛玻璃遮盖)来自 msimg32。
#pragma comment(lib, "msimg32.lib")

namespace {

constexpr wchar_t kLyricWindowClass[] = L"MusicFlowDesktopLyric";
constexpr wchar_t kRegKey[] = L"Software\\MusicFlow";
constexpr wchar_t kRegPosX[] = L"LyricX";
constexpr wchar_t kRegPosY[] = L"LyricY";

// ---- 布局常量(逻辑像素,实际使用时按 DPI 缩放 S()) ----
constexpr int kWindowWidth = 520;     // 窗口固定宽度
constexpr int kWindowHeight = 84;     // 歌词区固定高度
constexpr int kPaddingX = 26;         // 文字左边距
constexpr int kShadowOffset = 2;      // 文字阴影偏移
constexpr BYTE kWindowAlpha = 210;    // 整窗透明度(0-255)
constexpr int kCornerRadius = 12;     // 圆角半径
constexpr int kHeaderFontSize = 13;   // 「歌名 - 歌手」字号
constexpr int kLyricFontSize = 24;    // 歌词字号
constexpr int kPopupFontSize = 13;    // 音量百分比字号
constexpr int kPopupHeight = 162;     // 音量弹窗区高度(歌词区上方预留)

constexpr COLORREF kBgColor = RGB(28, 28, 34);        // 深色圆角背景
constexpr COLORREF kFrostColor = RGB(212, 218, 228);  // 毛玻璃遮罩色调
constexpr COLORREF kHeaderColor = RGB(142, 147, 158); // 标题行灰
constexpr COLORREF kTextColor = RGB(237, 239, 243);   // 歌词主色
constexpr COLORREF kShadowColor = RGB(0, 0, 0);       // 阴影色
constexpr COLORREF kBtnBg = RGB(38, 40, 47);          // 普通按钮底
constexpr COLORREF kPlayBtnBg = RGB(46, 49, 58);      // 播放按钮底(稍亮)
constexpr COLORREF kIconColor = RGB(215, 218, 224);   // 图标常规色
constexpr COLORREF kHoverBg = RGB(38, 62, 86);        // 悬停高亮底(蓝调)
constexpr COLORREF kLikeHoverBg = RGB(86, 40, 48);    // 喜欢悬停高亮(红调)
constexpr COLORREF kLikeColor = RGB(226, 75, 74);     // 已喜欢红
constexpr COLORREF kPanelBg = RGB(34, 36, 43);        // 音量弹窗底
constexpr COLORREF kPanelBorder = RGB(74, 78, 88);    // 弹窗描边
constexpr COLORREF kTrackColor = RGB(58, 61, 69);     // 滑条槽
constexpr COLORREF kTrackFill = RGB(55, 138, 221);    // 滑条已填充(蓝)
constexpr COLORREF kThumbColor = RGB(255, 255, 255);  // 滑块

// 按钮(圆心,逻辑坐标,自右缘向左排;窗口宽 W,歌词区高 84,中线 y=弹窗高+42):
// 上一首 / 播放暂停(大) / 下一首 / 播放模式 / 音量 / 喜欢(最贴边)
constexpr int kBtnR = 17;             // 普通按钮半径
constexpr int kPlayR = 22;            // 播放按钮半径
// 圆心相对右缘的偏移(逻辑 px): like=35, volume=87, mode=139, next=191,
// play=245, prev=299
constexpr int kOffLike = 35;
constexpr int kOffVolume = 87;
constexpr int kOffMode = 139;
constexpr int kOffNext = 191;
constexpr int kOffPlay = 245;
constexpr int kOffPrev = 299;
constexpr int kMaskExtra = 12;        // 遮罩左缘比最左按钮再多留的宽度

// 播放模式(与 Dart PlaybackMode 枚举顺序对齐: 0=shuffle,1=repeatAll,2=repeatOne)
constexpr int kModeShuffle = 0;
constexpr int kModeRepeatAll = 1;
constexpr int kModeRepeatOne = 2;

// Segoe MDL2 Assets 图标码点(Windows 10/11 系统自带)。
constexpr wchar_t kGlyphPrev = L'\uE892';
constexpr wchar_t kGlyphNext = L'\uE893';
constexpr wchar_t kGlyphPlay = L'\uE768';
constexpr wchar_t kGlyphPause = L'\uE769';
constexpr wchar_t kGlyphVolume = L'\uE767';
constexpr wchar_t kGlyphShuffle = L'\uE8B1';
constexpr wchar_t kGlyphRepeatAll = L'\uE8EE';
constexpr wchar_t kGlyphRepeatOne = L'\uE8ED';
constexpr wchar_t kGlyphHeart = L'\uEB51';       // 描边心形
constexpr wchar_t kGlyphHeartFill = L'\uEB52';   // 实心心形

HWND g_hwnd = nullptr;
HFONT g_lyricFont = nullptr;
HFONT g_headerFont = nullptr;
HFONT g_popupFont = nullptr;
HFONT g_iconFont = nullptr;      // 普通按钮图标(Segoe MDL2 Assets)
HFONT g_iconPlayFont = nullptr;  // 播放按钮图标(大一号)
std::wstring g_song;
std::wstring g_artist;
std::wstring g_lyric;
bool g_playing = false;
bool g_liked = false;
int g_mode = kModeRepeatAll;
double g_volume = 0.8;
bool g_visible = false;
bool g_dragging = false;
bool g_hovering = false;       // 鼠标是否在窗口内(决定遮罩/按钮显示)
bool g_trackingMouse = false;  // TrackMouseEvent 是否已登记
bool g_popupOpen = false;      // 音量弹窗是否展开
bool g_sliderDragging = false; // 正在拖音量滑条
int g_hotButton = -1;          // 悬停按钮索引
int g_pressedButton = -1;      // 按下中的按钮索引
POINT g_dragOffset{};

DesktopLyricEventCallback g_eventCb = nullptr;

// DPI 缩放
int g_dpi = 96;
float g_scale = 1.0f;
int g_curWidth = kWindowWidth;
int g_curHeight = kWindowHeight;
int g_padX = kPaddingX;
int g_shadowOffset = kShadowOffset;
int g_popupH = kPopupHeight;

int S(int v) { return static_cast<int>(v * g_scale + 0.5f); }

// 窗口总高固定 = 歌词区 + 弹窗区;弹窗区平时通过窗口区域裁剪排除,
// 真正透明且不接收鼠标,杜绝分层窗口 resize 后旧画面残影(双浮窗 bug)。
int TotalHeight() { return g_curHeight + g_popupH; }

// 按钮几何:圆心(物理 px)与半径。idx: 0=prev 1=play 2=next 3=mode 4=volume 5=like
struct BtnGeom {
  int cx, cy, r;
};

BtnGeom ButtonGeom(int idx) {
  const int w = g_curWidth;
  const int cy = g_popupH + g_curHeight / 2;
  switch (idx) {
    case 0: return {w - S(kOffPrev), cy, S(kBtnR)};
    case 1: return {w - S(kOffPlay), cy, S(kPlayR)};
    case 2: return {w - S(kOffNext), cy, S(kBtnR)};
    case 3: return {w - S(kOffMode), cy, S(kBtnR)};
    case 4: return {w - S(kOffVolume), cy, S(kBtnR)};
    default: return {w - S(kOffLike), cy, S(kBtnR)};
  }
}

// 按钮区遮罩左缘(物理 px):最左按钮(prev)左缘再外扩一点。
int MaskLeft() {
  return g_curWidth - S(kOffPrev + kBtnR + kMaskExtra);
}

// 音量弹窗面板(物理 px),位于窗口顶部弹窗区。
RECT PanelRect() {
  const int volCx = g_curWidth - S(kOffVolume);
  RECT rc{};
  rc.left = volCx - S(32);
  rc.right = volCx + S(32);
  rc.top = S(8);
  rc.bottom = g_popupH - S(8);
  return rc;
}

// 滑条轨道(物理 px)。
RECT TrackRect() {
  const int volCx = g_curWidth - S(kOffVolume);
  const RECT panel = PanelRect();
  RECT rc{};
  rc.left = volCx - S(3);
  rc.right = volCx + S(3);
  rc.top = panel.top + S(24);
  rc.bottom = panel.bottom - S(12);
  return rc;
}

bool PtInCircle(const POINT& pt, const BtnGeom& b) {
  const int dx = pt.x - b.cx;
  const int dy = pt.y - b.cy;
  return dx * dx + dy * dy <= b.r * b.r;
}

// 命中测试(窗口客户区物理坐标)。返回 -1 表示不在任何按钮上。
int HitTestButton(const POINT& pt) {
  if (!g_hovering) return -1;
  for (int i = 5; i >= 0; --i) {
    if (PtInCircle(pt, ButtonGeom(i))) return i;
  }
  return -1;
}

bool PtInPanel(const POINT& pt) {
  if (!g_popupOpen) return false;
  const RECT rc = PanelRect();
  return pt.x >= rc.left && pt.x < rc.right && pt.y >= rc.top &&
         pt.y < rc.bottom;
}

// ---- 事件回调 ----
void FireEvent(const std::string& msg) {
  if (g_eventCb) g_eventCb(msg.c_str());
}

// ---- 窗口区域:歌词区常驻;弹窗展开时把弹窗面板并入可见区域 ----
void ApplyWindowRegion() {
  if (!g_hwnd) return;
  const int w = g_curWidth;
  const int rad = S(kCornerRadius);
  // 歌词区(窗口下部,圆角)。
  HRGN region = CreateRoundRectRgn(0, g_popupH, w + 1, TotalHeight() + 1, rad,
                                   rad);
  if (g_popupOpen) {
    const RECT p = PanelRect();
    HRGN panel = CreateRoundRectRgn(p.left, p.top, p.right + 1, p.bottom + 1,
                                    S(8), S(8));
    // 连接带:面板底缘与歌词区之间的空隙并入窗口,否则鼠标从歌词栏
    // 移向音量面板时会穿过不可见区触发 WM_MOUSELEAVE,弹窗提前收起。
    HRGN bridge = CreateRectRgn(p.left, p.bottom, p.right + 1, g_popupH + 1);
    HRGN combined = CreateRectRgn(0, 0, 0, 0);
    CombineRgn(combined, region, panel, RGN_OR);
    CombineRgn(combined, combined, bridge, RGN_OR);
    DeleteObject(panel);
    DeleteObject(bridge);
    DeleteObject(region);
    region = combined;
  }
  // SetWindowRgn 后 region 归系统所有,不再 DeleteObject。
  SetWindowRgn(g_hwnd, region, FALSE);
}

void SetPopupOpen(bool open) {
  if (g_popupOpen == open) return;
  g_popupOpen = open;
  if (!open) g_sliderDragging = false;
  ApplyWindowRegion();
  InvalidateRect(g_hwnd, nullptr, TRUE);
}

// ---- 字体/布局随 DPI 重建 ----
void ApplyDpiScale(int dpi) {
  if (dpi <= 0) dpi = 96;
  if (dpi == g_dpi && g_lyricFont) return;
  g_dpi = dpi;
  g_scale = dpi / 96.0f;
  auto makeFont = [&](int logicalSize, bool bold, const wchar_t* face,
                      DWORD quality) {
    return CreateFontW(-S(logicalSize), 0, 0, 0, bold ? FW_BOLD : FW_NORMAL,
                       FALSE, FALSE, FALSE, DEFAULT_CHARSET,
                       OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, quality,
                       DEFAULT_PITCH | FF_DONTCARE, face);
  };
  if (g_lyricFont) DeleteObject(g_lyricFont);
  if (g_headerFont) DeleteObject(g_headerFont);
  if (g_popupFont) DeleteObject(g_popupFont);
  if (g_iconFont) DeleteObject(g_iconFont);
  if (g_iconPlayFont) DeleteObject(g_iconPlayFont);
  g_lyricFont = makeFont(kLyricFontSize, true, L"Microsoft YaHei UI",
                         CLEARTYPE_QUALITY);
  g_headerFont =
      makeFont(kHeaderFontSize, false, L"Microsoft YaHei UI", CLEARTYPE_QUALITY);
  g_popupFont =
      makeFont(kPopupFontSize, false, L"Microsoft YaHei UI", CLEARTYPE_QUALITY);
  g_iconFont =
      makeFont(20, false, L"Segoe MDL2 Assets", ANTIALIASED_QUALITY);
  g_iconPlayFont =
      makeFont(26, false, L"Segoe MDL2 Assets", ANTIALIASED_QUALITY);
  g_curWidth = S(kWindowWidth);
  g_curHeight = S(kWindowHeight);
  g_padX = S(kPaddingX);
  g_shadowOffset = S(kShadowOffset);
  g_popupH = S(kPopupHeight);
  if (g_hwnd) {
    ApplyWindowRegion();
    InvalidateRect(g_hwnd, nullptr, TRUE);
  }
}

void SaveLyricPos() {
  if (!g_hwnd) return;
  RECT rc{};
  GetWindowRect(g_hwnd, &rc);
  // 保存「歌词区」左上角(= 窗口顶 + 弹窗区高)。
  const LONG top = rc.top + g_popupH;
  RegSetKeyValueW(HKEY_CURRENT_USER, kRegKey, kRegPosX, REG_DWORD, &rc.left,
                  sizeof(DWORD));
  RegSetKeyValueW(HKEY_CURRENT_USER, kRegKey, kRegPosY, REG_DWORD, &top,
                  sizeof(DWORD));
}

void RestoreLyricPos(int* x, int* y) {
  DWORD savedX = 0, savedY = 0;
  DWORD size = sizeof(DWORD);
  bool okX = RegGetValueW(HKEY_CURRENT_USER, kRegKey, kRegPosX, RRF_RT_REG_DWORD,
                          nullptr, &savedX, &size) == ERROR_SUCCESS;
  size = sizeof(DWORD);
  bool okY = RegGetValueW(HKEY_CURRENT_USER, kRegKey, kRegPosY, RRF_RT_REG_DWORD,
                          nullptr, &savedY, &size) == ERROR_SUCCESS;
  if (!okX || !okY) return;
  RECT wa{};
  SystemParametersInfoW(SPI_GETWORKAREA, 0, &wa, 0);
  if (static_cast<int>(savedX) >= wa.left &&
      static_cast<int>(savedX) < wa.right &&
      static_cast<int>(savedY) >= wa.top &&
      static_cast<int>(savedY) < wa.bottom) {
    *x = static_cast<int>(savedX);
    *y = static_cast<int>(savedY);
  }
  if (*x + g_curWidth > wa.right) *x = wa.right - g_curWidth - 80;
  if (*y + g_curHeight > wa.bottom) *y = wa.bottom - g_curHeight - 40;
  if (*x < wa.left) *x = wa.left;
  if (*y < wa.top) *y = wa.top;
}

void RepaintLyric() {
  if (g_hwnd) InvalidateRect(g_hwnd, nullptr, FALSE);
}

// ---- 图标绘制:Segoe MDL2 Assets 字形,居中输出 ----
void DrawGlyph(HDC hdc, int cx, int cy, wchar_t glyph, HFONT font,
               COLORREF color) {
  if (!font) return;
  HFONT old = static_cast<HFONT>(SelectObject(hdc, font));
  SetBkMode(hdc, TRANSPARENT);
  SetTextColor(hdc, color);
  SIZE sz{};
  GetTextExtentPoint32W(hdc, &glyph, 1, &sz);
  TextOutW(hdc, cx - sz.cx / 2, cy - sz.cy / 2, &glyph, 1);
  SelectObject(hdc, old);
}

void DrawButton(HDC hdc, int idx) {
  const BtnGeom b = ButtonGeom(idx);
  const bool hot = g_hovering && g_hotButton == idx;
  // 悬停高亮圆形底。
  if (hot) {
    const int pad = S(4);
    RECT hl{b.cx - b.r - pad, b.cy - b.r - pad, b.cx + b.r + pad,
            b.cy + b.r + pad};
    const COLORREF hlColor = idx == 5 ? kLikeHoverBg : kHoverBg;
    HBRUSH br = CreateSolidBrush(hlColor);
    HBRUSH old = static_cast<HBRUSH>(SelectObject(hdc, br));
    HPEN pen = CreatePen(PS_SOLID, 1, hlColor);
    HPEN oldPen = static_cast<HPEN>(SelectObject(hdc, pen));
    Ellipse(hdc, hl.left, hl.top, hl.right, hl.bottom);
    SelectObject(hdc, oldPen);
    SelectObject(hdc, old);
    DeleteObject(pen);
    DeleteObject(br);
  }
  // 按钮圆底。
  HBRUSH br = CreateSolidBrush(idx == 1 ? kPlayBtnBg : kBtnBg);
  HBRUSH oldBr = static_cast<HBRUSH>(SelectObject(hdc, br));
  HPEN pen = CreatePen(PS_SOLID, 1, kBtnBg);
  HPEN oldPen = static_cast<HPEN>(SelectObject(hdc, pen));
  Ellipse(hdc, b.cx - b.r, b.cy - b.r, b.cx + b.r, b.cy + b.r);
  SelectObject(hdc, oldPen);
  SelectObject(hdc, oldBr);
  DeleteObject(pen);
  DeleteObject(br);
  // 图标(Segoe MDL2 Assets 字形)。
  const COLORREF iconColor =
      hot ? RGB(255, 255, 255)
          : (idx == 5 && g_liked ? kLikeColor : kIconColor);
  wchar_t glyph = 0;
  HFONT font = g_iconFont;
  switch (idx) {
    case 0: glyph = kGlyphPrev; break;
    case 1:
      glyph = g_playing ? kGlyphPause : kGlyphPlay;
      font = g_iconPlayFont;
      break;
    case 2: glyph = kGlyphNext; break;
    case 3:
      glyph = g_mode == kModeShuffle
                  ? kGlyphShuffle
                  : (g_mode == kModeRepeatOne ? kGlyphRepeatOne
                                              : kGlyphRepeatAll);
      break;
    case 4: glyph = kGlyphVolume; break;
    case 5: glyph = g_liked ? kGlyphHeartFill : kGlyphHeart; break;
  }
  DrawGlyph(hdc, b.cx, b.cy, glyph, font, iconColor);
}

void DrawVolumePopup(HDC hdc) {
  if (!g_popupOpen) return;
  const RECT panel = PanelRect();
  // 面板底 + 描边。
  HBRUSH br = CreateSolidBrush(kPanelBg);
  HBRUSH old = static_cast<HBRUSH>(SelectObject(hdc, br));
  HBRUSH frameBr = CreateSolidBrush(kPanelBorder);
  RECT rr = panel;
  const int rad = S(8);
  HRGN rgn = CreateRoundRectRgn(rr.left, rr.top, rr.right + 1, rr.bottom + 1,
                                rad, rad);
  FillRgn(hdc, rgn, br);
  FrameRgn(hdc, rgn, frameBr, 1, 1);
  DeleteObject(rgn);
  SelectObject(hdc, old);
  DeleteObject(frameBr);
  DeleteObject(br);
  // 连接带(面板与歌词区之间的桥接矩形,在窗口区域内)用面板底色填满,
  // 视觉上面板一直延伸到歌词栏,也避免双缓冲位图的未绘制垃圾露出来。
  RECT bridgeFill{panel.left + 1, panel.bottom, panel.right - 1, g_popupH};
  HBRUSH bridgeBr = CreateSolidBrush(kPanelBg);
  FillRect(hdc, &bridgeFill, bridgeBr);
  DeleteObject(bridgeBr);
  // 百分比。
  wchar_t label[16];
  swprintf(label, 16, L"%d%%",
           static_cast<int>(std::lround(g_volume * 100.0)));
  if (g_popupFont) {
    SetBkMode(hdc, TRANSPARENT);
    HFONT oldF = static_cast<HFONT>(SelectObject(hdc, g_popupFont));
    SetTextColor(hdc, kTextColor);
    SIZE sz{};
    GetTextExtentPoint32W(hdc, label, static_cast<int>(wcslen(label)), &sz);
    TextOutW(hdc, (panel.left + panel.right - sz.cx) / 2, panel.top + S(4),
             label, static_cast<int>(wcslen(label)));
    SelectObject(hdc, oldF);
  }
  // 滑条:槽 + 已填充 + 滑块。
  const RECT tr = TrackRect();
  RECT track{tr.left, tr.top, tr.right, tr.bottom};
  HBRUSH trackBr = CreateSolidBrush(kTrackColor);
  FillRect(hdc, &track, trackBr);
  DeleteObject(trackBr);
  const int thumbCy =
      tr.bottom - static_cast<int>((tr.bottom - tr.top) * g_volume);
  if (thumbCy < tr.bottom) {
    RECT filled{tr.left, thumbCy, tr.right, tr.bottom};
    HBRUSH fillBr = CreateSolidBrush(kTrackFill);
    FillRect(hdc, &filled, fillBr);
    DeleteObject(fillBr);
  }
  const int thumbR = S(7);
  HBRUSH thumbBr = CreateSolidBrush(kThumbColor);
  HBRUSH oldBr = static_cast<HBRUSH>(SelectObject(hdc, thumbBr));
  Ellipse(hdc, tr.left + (tr.right - tr.left) / 2 - thumbR,
          thumbCy - thumbR, tr.left + (tr.right - tr.left) / 2 + thumbR,
          thumbCy + thumbR);
  SelectObject(hdc, oldBr);
  DeleteObject(thumbBr);
}

// 滑条上按 y 反解音量(0..1)。
double VolumeFromY(int y) {
  const RECT tr = TrackRect();
  const int h = tr.bottom - tr.top;
  if (h <= 0) return g_volume;
  double v = 1.0 - static_cast<double>(y - tr.top) / h;
  if (v < 0.0) v = 0.0;
  if (v > 1.0) v = 1.0;
  return v;
}

void SetVolumeAndNotify(double v) {
  if (std::fabs(v - g_volume) < 0.005) return;
  g_volume = v;
  char buf[32];
  snprintf(buf, sizeof(buf), "volume:%.2f", v);
  FireEvent(buf);
  RepaintLyric();
}

// 按钮区毛玻璃遮盖:浅色半透明 + 顶部高光渐变(逐行预乘 alpha),
// 比实色遮罩更有磨砂玻璃质感;按钮绘制在其上保持清晰。
void DrawFrostMask(HDC hdc, const RECT& rc) {
  const int w = rc.right - rc.left;
  const int h = rc.bottom - rc.top;
  if (w <= 0 || h <= 0) return;
  HDC mem = CreateCompatibleDC(hdc);
  if (!mem) return;
  BITMAPINFO bi{};
  bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bi.bmiHeader.biWidth = w;
  bi.bmiHeader.biHeight = -h;  // top-down
  bi.bmiHeader.biPlanes = 1;
  bi.bmiHeader.biBitCount = 32;
  bi.bmiHeader.biCompression = BI_RGB;
  void* bits = nullptr;
  HBITMAP bmp =
      CreateDIBSection(mem, &bi, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (!bmp || !bits) {
    if (bmp) DeleteObject(bmp);
    DeleteDC(mem);
    return;
  }
  HBITMAP oldBmp = static_cast<HBITMAP>(SelectObject(mem, bmp));
  // 逐行填充:alpha 顶部 92 → 底部 64,颜色需预乘(AC_SRC_ALPHA 要求)。
  // COLORREF 布局 0x00bbggrr;不用 GetXValue 宏(对 constexpr 截断会触发 C4310)。
  const int r0 = kFrostColor & 0xFF;
  const int g0 = (kFrostColor >> 8) & 0xFF;
  const int b0 = (kFrostColor >> 16) & 0xFF;
  auto* px = static_cast<DWORD*>(bits);
  for (int y = 0; y < h; ++y) {
    const int a = 92 - (92 - 64) * y / std::max(1, h - 1);
    const DWORD pr = static_cast<DWORD>(r0 * a / 255);
    const DWORD pg = static_cast<DWORD>(g0 * a / 255);
    const DWORD pb = static_cast<DWORD>(b0 * a / 255);
    const DWORD v = (static_cast<DWORD>(a) << 24) | (pr << 16) | (pg << 8) | pb;
    for (int x = 0; x < w; ++x) *px++ = v;
  }
  BLENDFUNCTION bf{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
  AlphaBlend(hdc, rc.left, rc.top, w, h, mem, 0, 0, w, h, bf);
  // 左缘发丝线,强化玻璃面板边界。
  HPEN pen = CreatePen(PS_SOLID, 1, RGB(96, 102, 112));
  HPEN oldPen = static_cast<HPEN>(SelectObject(hdc, pen));
  MoveToEx(hdc, rc.left, rc.top, nullptr);
  LineTo(hdc, rc.left, rc.bottom);
  SelectObject(hdc, oldPen);
  DeleteObject(pen);
  SelectObject(mem, oldBmp);
  DeleteObject(bmp);
  DeleteDC(mem);
}

LRESULT CALLBACK LyricWndProc(HWND hwnd, UINT message, WPARAM wParam,
                              LPARAM lParam) {
  switch (message) {
    case WM_PAINT: {
      PAINTSTRUCT ps;
      HDC hdc = BeginPaint(hwnd, &ps);
      RECT rc{};
      GetClientRect(hwnd, &rc);
      const int w = rc.right - rc.left;
      const int h = rc.bottom - rc.top;
      // 双缓冲:全部内容先画进内存位图,最后一次 BitBlt 上屏。
      // 拖音量滑条等高频重绘时,无缓冲会看到遮罩/背景逐层绘制而闪烁。
      HDC buf = CreateCompatibleDC(hdc);
      HBITMAP bmp = CreateCompatibleBitmap(hdc, w, h);
      if (!buf || !bmp) {
        if (buf) DeleteDC(buf);
        if (bmp) DeleteObject(bmp);
        EndPaint(hwnd, &ps);
        return 0;
      }
      HBITMAP oldBmp = static_cast<HBITMAP>(SelectObject(buf, bmp));
      hdc = buf;
      // 全窗口按圆角裁剪(窗口区域已保证弹窗区不可见)。
      HRGN clip = CreateRoundRectRgn(0, 0, w + 1, h + 1, S(kCornerRadius),
                                     S(kCornerRadius));
      SelectClipRgn(hdc, clip);
      // 歌词区圆角背景(窗口下部,常驻)。
      HRGN bg = CreateRoundRectRgn(0, g_popupH, w + 1, h + 1, S(kCornerRadius),
                                   S(kCornerRadius));
      HBRUSH brush = CreateSolidBrush(kBgColor);
      FillRgn(hdc, bg, brush);
      DeleteObject(brush);
      DeleteObject(bg);
      // 两行文字:标题行(歌名 - 歌手) + 歌词行(空则 MusicFlow)。
      const int baseY = g_popupH;
      std::wstring header = g_artist.empty() ? g_song : (g_song + L" - " + g_artist);
      std::wstring lyric = g_lyric.empty() ? L"MusicFlow" : g_lyric;
      SetBkMode(hdc, TRANSPARENT);
      if (g_headerFont && !header.empty()) {
        HFONT old = static_cast<HFONT>(SelectObject(hdc, g_headerFont));
        SIZE sz{};
        GetTextExtentPoint32W(hdc, header.c_str(),
                              static_cast<int>(header.size()), &sz);
        const int y = baseY + static_cast<int>(g_curHeight * 0.20f) - sz.cy / 2;
        SetTextColor(hdc, kShadowColor);
        TextOutW(hdc, g_padX + g_shadowOffset, y + g_shadowOffset,
                 header.c_str(), static_cast<int>(header.size()));
        SetTextColor(hdc, kHeaderColor);
        TextOutW(hdc, g_padX, y, header.c_str(),
                 static_cast<int>(header.size()));
        SelectObject(hdc, old);
      }
      if (g_lyricFont && !lyric.empty()) {
        HFONT old = static_cast<HFONT>(SelectObject(hdc, g_lyricFont));
        SIZE sz{};
        GetTextExtentPoint32W(hdc, lyric.c_str(), static_cast<int>(lyric.size()),
                              &sz);
        const int y = baseY + static_cast<int>(g_curHeight * 0.66f) - sz.cy / 2;
        SetTextColor(hdc, kShadowColor);
        TextOutW(hdc, g_padX + g_shadowOffset, y + g_shadowOffset,
                 lyric.c_str(), static_cast<int>(lyric.size()));
        SetTextColor(hdc, kTextColor);
        TextOutW(hdc, g_padX, y, lyric.c_str(), static_cast<int>(lyric.size()));
        SelectObject(hdc, old);
      }
      // 悬停时:按钮区毛玻璃遮罩 + 按钮。平时不画,保持纯歌词。
      if (g_hovering) {
        RECT mask{MaskLeft(), baseY, w, baseY + g_curHeight};
        DrawFrostMask(hdc, mask);
        for (int i = 0; i < 6; ++i) DrawButton(hdc, i);
      }
      DrawVolumePopup(hdc);
      SelectClipRgn(hdc, nullptr);
      DeleteObject(clip);
      // 一次性上屏。
      hdc = ps.hdc;
      BitBlt(hdc, 0, 0, w, h, buf, 0, 0, SRCCOPY);
      SelectObject(buf, oldBmp);
      DeleteObject(bmp);
      DeleteDC(buf);
      EndPaint(hwnd, &ps);
      return 0;
    }
    case WM_ERASEBKGND:
      return 1;
    case WM_MOUSEMOVE: {
      POINT pt{GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam)};
      if (g_dragging) {
        POINT cur{};
        GetCursorPos(&cur);
        SetWindowPos(hwnd, nullptr, cur.x - g_dragOffset.x,
                     cur.y - g_dragOffset.y, 0, 0,
                     SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
        return 0;
      }
      if (g_sliderDragging) {
        SetVolumeAndNotify(VolumeFromY(pt.y));
        return 0;
      }
      if (!g_trackingMouse) {
        TRACKMOUSEEVENT tme{sizeof(tme), TME_LEAVE, hwnd, 0};
        TrackMouseEvent(&tme);
        g_trackingMouse = true;
        if (!g_hovering) {
          g_hovering = true;
          RepaintLyric();
        }
      }
      const int hot = HitTestButton(pt);
      const bool inPanel = PtInPanel(pt);
      int newHot = hot;
      if (newHot < 0 && inPanel) newHot = 4;  // 弹窗内视作音量按钮高亮
      if (newHot != g_hotButton) {
        g_hotButton = newHot;
        RepaintLyric();
      }
      return 0;
    }
    case WM_MOUSELEAVE: {
      g_trackingMouse = false;
      g_hovering = false;
      g_hotButton = -1;
      g_sliderDragging = false;
      SetPopupOpen(false);
      RepaintLyric();
      return 0;
    }
    case WM_LBUTTONDOWN: {
      POINT pt{GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam)};
      const int btn = HitTestButton(pt);
      if (btn >= 0) {
        // 按钮按下:记录,不进入拖动。
        g_pressedButton = btn;
        SetCapture(hwnd);
        return 0;
      }
      if (PtInPanel(pt)) {
        // 弹窗面板内:滑条区域开始拖动,其余点击吞掉。
        const RECT tr = TrackRect();
        if (pt.x >= tr.left - S(14) && pt.x <= tr.right + S(14) &&
            pt.y >= tr.top - S(6) && pt.y <= tr.bottom + S(6)) {
          g_sliderDragging = true;
          SetCapture(hwnd);
          SetVolumeAndNotify(VolumeFromY(pt.y));
        }
        return 0;
      }
      if (g_popupOpen) {
        // 点弹窗外(含歌词区):收起弹窗。
        SetPopupOpen(false);
        RepaintLyric();
        return 0;
      }
      // 其余区域:拖动窗口。
      SetCapture(hwnd);
      g_dragging = true;
      g_dragOffset.x = GET_X_LPARAM(lParam);
      g_dragOffset.y = GET_Y_LPARAM(lParam);
      return 0;
    }
    case WM_LBUTTONUP: {
      if (g_sliderDragging) {
        g_sliderDragging = false;
        ReleaseCapture();
        return 0;
      }
      if (g_pressedButton >= 0) {
        const int btn = g_pressedButton;
        g_pressedButton = -1;
        ReleaseCapture();
        POINT pt{GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam)};
        if (HitTestButton(pt) == btn) {
          switch (btn) {
            case 0: FireEvent("previous"); break;
            case 1: FireEvent("toggle_play_pause"); break;
            case 2: FireEvent("next"); break;
            case 3: FireEvent("cycle_playback_mode"); break;
            case 4: SetPopupOpen(!g_popupOpen); break;
            case 5:
              // 乐观翻转:star/unstar 有网络往返,先立即变红/取消,
              // Dart 稍后推送真实状态,DesktopLyricUpdateState 会校正。
              g_liked = !g_liked;
              RepaintLyric();
              FireEvent("toggle_like");
              break;
          }
        }
        return 0;
      }
      if (g_dragging) {
        g_dragging = false;
        ReleaseCapture();
        SaveLyricPos();
      }
      return 0;
    }
    case WM_CAPTURECHANGED:
      g_pressedButton = -1;
      g_sliderDragging = false;
      return 0;
    case WM_RBUTTONUP: {
      HMENU menu = CreatePopupMenu();
      AppendMenuW(menu, MF_STRING, 1, L"隐藏歌词(&H)");
      POINT pt{};
      GetCursorPos(&pt);
      SetForegroundWindow(hwnd);
      const int cmd = TrackPopupMenu(menu,
                                     TPM_RIGHTALIGN | TPM_BOTTOMALIGN |
                                         TPM_RETURNCMD,
                                     pt.x, pt.y, 0, hwnd, nullptr);
      DestroyMenu(menu);
      PostMessageW(hwnd, WM_NULL, 0, 0);
      if (cmd == 1) DesktopLyricSetVisible(false);
      return 0;
    }
    case WM_DPICHANGED: {
      ApplyDpiScale(HIWORD(wParam));
      const RECT* suggested = reinterpret_cast<const RECT*>(lParam);
      SetWindowPos(hwnd, nullptr, suggested->left, suggested->top,
                   g_curWidth, TotalHeight(), SWP_NOZORDER | SWP_NOACTIVATE);
      return 0;
    }
    default:
      return DefWindowProcW(hwnd, message, wParam, lParam);
  }
}

}  // namespace

void DesktopLyricInit(HINSTANCE instance) {
  if (g_hwnd) return;
  WNDCLASSEXW wc{};
  wc.cbSize = sizeof(wc);
  wc.lpfnWndProc = LyricWndProc;
  wc.hInstance = instance;
  wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
  wc.hbrBackground = nullptr;
  wc.lpszClassName = kLyricWindowClass;
  RegisterClassExW(&wc);

  UINT dpi = 96;
  const auto getDpiForSystem =
      reinterpret_cast<UINT(WINAPI*)()>(
          GetProcAddress(GetModuleHandleW(L"user32.dll"), "GetDpiForSystem"));
  if (getDpiForSystem) dpi = getDpiForSystem();
  ApplyDpiScale(static_cast<int>(dpi));

  RECT wa{};
  SystemParametersInfoW(SPI_GETWORKAREA, 0, &wa, 0);
  // x/y 为「歌词区」左上角;窗口顶还要再向上让出弹窗区。
  int x = wa.right - g_curWidth - 80;
  int y = wa.bottom - g_curHeight - 40;
  RestoreLyricPos(&x, &y);

  g_hwnd = CreateWindowExW(
      WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_LAYERED, kLyricWindowClass,
      L"MusicFlowLyric", WS_POPUP, x, y - g_popupH, g_curWidth, TotalHeight(),
      nullptr, nullptr, instance, nullptr);
  if (!g_hwnd) return;
  SetLayeredWindowAttributes(g_hwnd, 0, kWindowAlpha, LWA_ALPHA);
  ApplyWindowRegion();
  const auto getDpiForWindow =
      reinterpret_cast<UINT(WINAPI*)(HWND)>(
          GetProcAddress(GetModuleHandleW(L"user32.dll"), "GetDpiForWindow"));
  if (getDpiForWindow) {
    ApplyDpiScale(static_cast<int>(getDpiForWindow(g_hwnd)));
  }
}

void DesktopLyricSetEventCallback(DesktopLyricEventCallback callback) {
  g_eventCb = callback;
}

void DesktopLyricUpdateState(const DesktopLyricState& state) {
  const bool changed = g_song != state.song || g_artist != state.artist ||
                       g_lyric != state.lyric || g_playing != state.playing ||
                       g_liked != state.liked || g_mode != state.mode ||
                       std::fabs(g_volume - state.volume) > 0.004;
  g_song = state.song;
  g_artist = state.artist;
  g_lyric = state.lyric;
  g_playing = state.playing;
  g_liked = state.liked;
  g_mode = state.mode;
  g_volume = state.volume;
  if (changed) RepaintLyric();
}

void DesktopLyricSetVisible(bool visible) {
  g_visible = visible;
  if (!g_hwnd) return;
  if (visible) {
    ShowWindow(g_hwnd, SW_SHOWNOACTIVATE);
    SetWindowPos(g_hwnd, HWND_TOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  } else {
    ShowWindow(g_hwnd, SW_HIDE);
  }
}

bool DesktopLyricIsVisible() { return g_visible; }

void DesktopLyricShutdown() {
  if (g_hwnd) {
    DestroyWindow(g_hwnd);
    g_hwnd = nullptr;
  }
  if (g_lyricFont) {
    DeleteObject(g_lyricFont);
    g_lyricFont = nullptr;
  }
  if (g_headerFont) {
    DeleteObject(g_headerFont);
    g_headerFont = nullptr;
  }
  if (g_popupFont) {
    DeleteObject(g_popupFont);
    g_popupFont = nullptr;
  }
  if (g_iconFont) {
    DeleteObject(g_iconFont);
    g_iconFont = nullptr;
  }
  if (g_iconPlayFont) {
    DeleteObject(g_iconPlayFont);
    g_iconPlayFont = nullptr;
  }
}
