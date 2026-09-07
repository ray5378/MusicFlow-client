#include "desktop_lyric.h"

#include <windowsx.h>
#include <objidl.h>
#include <gdiplus.h>

#include <algorithm>
#include <cmath>
#include <string>

// UpdateLayeredWindow 逐像素 alpha 合成需要 GDI+。
#pragma comment(lib, "gdiplus.lib")

namespace {

namespace gd = Gdiplus;
using gd::REAL;  // GDI+ 浮点类型,函数签名里大量使用

constexpr wchar_t kLyricWindowClass[] = L"MusicFlowDesktopLyric";
constexpr wchar_t kRegKey[] = L"Software\\MusicFlow";
constexpr wchar_t kRegPosX[] = L"LyricX";
constexpr wchar_t kRegPosY[] = L"LyricY";

// ---- 布局常量(逻辑像素,实际使用时按 DPI 缩放 S()) ----
constexpr int kWindowWidth = 520;     // 窗口固定宽度
constexpr int kWindowHeight = 84;     // 歌词区固定高度
constexpr int kPaddingX = 26;         // 文字左边距
constexpr int kCornerRadius = 12;     // 圆角半径
constexpr int kHeaderFontSize = 13;   // 「歌名 - 歌手」字号
constexpr int kLyricFontSize = 24;    // 歌词字号
constexpr int kPopupFontSize = 13;    // 音量百分比字号
constexpr int kPopupHeight = 162;     // 音量弹窗区高度(歌词区上方预留)
constexpr int kLyricStrokeW = 4;      // 歌词描边宽(逻辑)
constexpr int kHeaderStrokeW = 3;     // 标题描边宽(逻辑)

// 参考网易云桌面歌词:未悬停时无任何底板(完全透明),只有描边字;
// 悬停时出现整栏灰色半透明圆角面板,按钮绘制其上。
constexpr int kHoverPanelAlpha = 160;                 // 悬停面板不透明度
constexpr int kPopupPanelAlpha = 242;                 // 音量弹窗不透明度
constexpr COLORREF kHoverPanelColor = RGB(138, 138, 138);  // 悬停面板灰
constexpr COLORREF kLyricFillColor = RGB(240, 149, 149);   // 歌词填充默认色(粉)
constexpr COLORREF kHeaderFillColor = RGB(255, 255, 255);  // 标题填充(白)
constexpr COLORREF kHeaderStrokeColor = RGB(201, 201, 201);// 标题描边(浅灰)
constexpr COLORREF kTextColor = RGB(237, 239, 243);   // 弹窗文字
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
ULONG_PTR g_gdiplusToken = 0;
gd::FontFamily* g_famUI = nullptr;    // Microsoft YaHei UI
gd::FontFamily* g_famIcon = nullptr;  // Segoe MDL2 Assets
gd::Font* g_fontPopup = nullptr;      // 音量百分比
gd::Font* g_fontIcon = nullptr;       // 普通按钮图标
gd::Font* g_fontIconPlay = nullptr;   // 播放按钮图标(大一号)
gd::Bitmap* g_surface = nullptr;      // 分层窗口内容(PARGB,按需重建)
gd::Graphics* g_gfx = nullptr;
std::wstring g_song;
std::wstring g_artist;
std::wstring g_lyric;
COLORREF g_lyricColor = kLyricFillColor;  // 歌词填充色(Flutter 推送)
bool g_playing = false;
bool g_liked = false;
int g_mode = kModeRepeatAll;
double g_volume = 0.8;
bool g_visible = false;
bool g_dragging = false;
bool g_hovering = false;       // 鼠标是否在窗口内(决定面板/按钮显示)
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
int g_popupH = kPopupHeight;

int S(int v) { return static_cast<int>(v * g_scale + 0.5f); }
float Sf(int v) { return static_cast<float>(v) * g_scale; }

// 窗口总高固定 = 歌词区 + 弹窗区;弹窗区未画像素 alpha=0,
// 天然透明且不接收鼠标(等价旧 SetWindowRgn 裁剪)。
int TotalHeight() { return g_curHeight + g_popupH; }

// GDI+ COLORREF → Color(COLoRREF 布局 0x00bbggrr;不用 GetXValue 宏,
// 对 constexpr 截断会触发 C4310)。
gd::Color Gd(COLORREF c, int alpha = 255) {
  return gd::Color(static_cast<BYTE>(alpha), static_cast<BYTE>(c & 0xFF),
                   static_cast<BYTE>((c >> 8) & 0xFF),
                   static_cast<BYTE>((c >> 16) & 0xFF));
}

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

void RenderLayered();  // 前向声明:渲染入口在文件后部定义

// ---- 字体随 DPI 重建(GDI+ Font,UnitPixel 免去 DPI 换算) ----
void ApplyDpiScale(int dpi) {
  if (dpi <= 0) dpi = 96;
  if (dpi == g_dpi && g_fontPopup) return;
  g_dpi = dpi;
  g_scale = dpi / 96.0f;
  delete g_fontPopup;
  delete g_fontIcon;
  delete g_fontIconPlay;
  g_fontPopup =
      new gd::Font(g_famUI, Sf(kPopupFontSize), gd::FontStyleRegular,
                   gd::UnitPixel);
  g_fontIcon = new gd::Font(g_famIcon, Sf(20), gd::FontStyleRegular,
                            gd::UnitPixel);
  g_fontIconPlay = new gd::Font(g_famIcon, Sf(26), gd::FontStyleRegular,
                                gd::UnitPixel);
  g_curWidth = S(kWindowWidth);
  g_curHeight = S(kWindowHeight);
  g_padX = S(kPaddingX);
  g_popupH = S(kPopupHeight);
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

// ---- GDI+ 绘制辅助 ----

gd::GraphicsPath* RoundRectPath(REAL x, REAL y, REAL w, REAL h, REAL r) {
  auto* p = new gd::GraphicsPath();
  const REAL d = r * 2;
  p->AddArc(x, y, d, d, 180, 90);
  p->AddArc(x + w - d, y, d, d, 270, 90);
  p->AddArc(x + w - d, y + h - d, d, d, 0, 90);
  p->AddArc(x, y + h - d, d, d, 90, 90);
  p->CloseFigure();
  return p;
}

void FillRoundRect(gd::Graphics& g, REAL x, REAL y, REAL w, REAL h, REAL r,
                   const gd::Color& c) {
  gd::GraphicsPath* p = RoundRectPath(x, y, w, h, r);
  gd::SolidBrush br(c);
  g.FillPath(&br, p);
  delete p;
}

// 描边字:路径文字 → 先描边(DrawPath)再填充(FillPath),
// 视觉上填充居内、描边成环,与网易云效果一致。
void DrawOutlinedText(gd::Graphics& g, const std::wstring& text,
                      const gd::FontFamily* family, gd::FontStyle style,
                      REAL sizePx, REAL leftX, REAL centerY,
                      const gd::Color& fill, const gd::Color& stroke,
                      REAL strokeW) {
  if (text.empty() || family == nullptr) return;
  gd::GraphicsPath path;
  path.AddString(text.c_str(), static_cast<INT>(text.size()), family, style,
                 sizePx, gd::PointF(0, 0),
                 gd::StringFormat::GenericTypographic());
  gd::RectF bounds{};
  if (path.GetBounds(&bounds) != gd::Ok) return;
  gd::Matrix m;
  m.Translate(leftX - bounds.X, centerY - (bounds.Y + bounds.Height / 2));
  path.Transform(&m);
  gd::Pen pen(stroke, strokeW);
  pen.SetLineJoin(gd::LineJoinRound);
  pen.SetLineCap(gd::LineCapRound, gd::LineCapRound, gd::DashCapRound);
  g.DrawPath(&pen, &path);
  gd::SolidBrush br(fill);
  g.FillPath(&br, &path);
}

// 图标绘制:Segoe MDL2 Assets 字形,按字形 ink 外接框居中于按钮圆心
// (DrawString 的行盒居中会被字体行高带偏,这里与描边字同一套路径定位)。
void DrawGlyphGd(gd::Graphics& g, const BtnGeom& b, wchar_t glyph,
                 const gd::Font* font, const gd::Color& color) {
  if (!font) return;
  gd::FontFamily family;
  if (font->GetFamily(&family) != gd::Ok) return;
  gd::GraphicsPath path;
  path.AddString(&glyph, 1, &family, font->GetStyle(), font->GetSize(),
                 gd::PointF(0, 0), gd::StringFormat::GenericTypographic());
  gd::RectF bounds{};
  if (path.GetBounds(&bounds) != gd::Ok) return;
  gd::Matrix m;
  m.Translate(static_cast<REAL>(b.cx) - (bounds.X + bounds.Width / 2),
              static_cast<REAL>(b.cy) - (bounds.Y + bounds.Height / 2));
  path.Transform(&m);
  gd::SolidBrush br(color);
  g.FillPath(&br, &path);
}

void DrawButton(gd::Graphics& g, int idx) {
  const BtnGeom b = ButtonGeom(idx);
  const bool hot = g_hovering && g_hotButton == idx;
  // 悬停高亮圆形底。
  if (hot) {
    const int pad = S(4);
    gd::SolidBrush br(Gd(idx == 5 ? kLikeHoverBg : kHoverBg));
    g.FillEllipse(&br, static_cast<REAL>(b.cx - b.r - pad),
                  static_cast<REAL>(b.cy - b.r - pad),
                  static_cast<REAL>((b.r + pad) * 2),
                  static_cast<REAL>((b.r + pad) * 2));
  }
  // 按钮圆底。
  gd::SolidBrush br(Gd(idx == 1 ? kPlayBtnBg : kBtnBg));
  g.FillEllipse(&br, static_cast<REAL>(b.cx - b.r),
                static_cast<REAL>(b.cy - b.r), static_cast<REAL>(b.r * 2),
                static_cast<REAL>(b.r * 2));
  // 图标(Segoe MDL2 Assets 字形)。
  const gd::Color iconColor =
      Gd(hot ? RGB(255, 255, 255)
             : (idx == 5 && g_liked ? kLikeColor : kIconColor));
  wchar_t glyph = 0;
  const gd::Font* font = g_fontIcon;
  switch (idx) {
    case 0: glyph = kGlyphPrev; break;
    case 1:
      glyph = g_playing ? kGlyphPause : kGlyphPlay;
      font = g_fontIconPlay;
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
  DrawGlyphGd(g, b, glyph, font, iconColor);
}

void DrawVolumePopup(gd::Graphics& g) {
  if (!g_popupOpen) return;
  const RECT panel = PanelRect();
  const REAL px = static_cast<REAL>(panel.left);
  const REAL py = static_cast<REAL>(panel.top);
  const REAL pw = static_cast<REAL>(panel.right - panel.left);
  const REAL ph = static_cast<REAL>(panel.bottom - panel.top);
  const int rad = S(8);
  // 面板底 + 描边。
  FillRoundRect(g, px, py, pw, ph, static_cast<REAL>(rad),
                Gd(kPanelBg, kPopupPanelAlpha));
  {
    gd::GraphicsPath* p = RoundRectPath(px, py, pw, ph, static_cast<REAL>(rad));
    gd::Pen pen(Gd(kPanelBorder), 1.0f);
    g.DrawPath(&pen, p);
    delete p;
  }
  // 连接带(面板与歌词区之间的桥接矩形)用面板底色填满,视觉上面板
  // 一直延伸到歌词栏。
  {
    gd::SolidBrush br(Gd(kPanelBg, kPopupPanelAlpha));
    g.FillRectangle(&br, px + 1, py + ph, pw - 2,
                    static_cast<REAL>(g_popupH - panel.bottom));
  }
  // 百分比。
  wchar_t label[16];
  swprintf(label, 16, L"%d%%",
           static_cast<int>(std::lround(g_volume * 100.0)));
  if (g_fontPopup) {
    gd::SolidBrush br(Gd(kTextColor));
    gd::StringFormat sf;
    sf.SetAlignment(gd::StringAlignmentCenter);
    sf.SetLineAlignment(gd::StringAlignmentCenter);
    g.DrawString(label, static_cast<INT>(wcslen(label)), g_fontPopup,
                 gd::RectF(px, py, pw, static_cast<REAL>(S(18))), &sf, &br);
  }
  // 滑条:槽 + 已填充 + 滑块。
  const RECT tr = TrackRect();
  gd::SolidBrush trackBr(Gd(kTrackColor));
  g.FillRectangle(&trackBr, static_cast<REAL>(tr.left),
                  static_cast<REAL>(tr.top),
                  static_cast<REAL>(tr.right - tr.left),
                  static_cast<REAL>(tr.bottom - tr.top));
  const int thumbCy =
      tr.bottom - static_cast<int>((tr.bottom - tr.top) * g_volume);
  if (thumbCy < tr.bottom) {
    gd::SolidBrush fillBr(Gd(kTrackFill));
    g.FillRectangle(&fillBr, static_cast<REAL>(tr.left),
                    static_cast<REAL>(thumbCy),
                    static_cast<REAL>(tr.right - tr.left),
                    static_cast<REAL>(tr.bottom - thumbCy));
  }
  const int thumbR = S(7);
  gd::SolidBrush thumbBr(Gd(kThumbColor));
  g.FillEllipse(&thumbBr, static_cast<REAL>(tr.left + (tr.right - tr.left) / 2 - thumbR),
                static_cast<REAL>(thumbCy - thumbR),
                static_cast<REAL>(thumbR * 2), static_cast<REAL>(thumbR * 2));
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
  RenderLayered();
}

// 歌词描边色随填充色自适应:亮字(如暖黄)→ 同色相向黑收深,避免在浅色
// 壁纸上糊掉;暗字 → 向白提亮保持描边清晰。
COLORREF ComputeLyricStrokeColor(COLORREF fill) {
  const int r = fill & 0xFF;
  const int g = (fill >> 8) & 0xFF;
  const int b = (fill >> 16) & 0xFF;
  const double lum = 0.299 * r + 0.587 * g + 0.114 * b;
  if (lum >= 150) {
    const auto darken = [](int c) {
      return static_cast<int>(c * 0.45 + 0.5);
    };
    return RGB(darken(r), darken(g), darken(b));
  }
  const auto lighten = [](int c) {
    return static_cast<int>(c + (255 - c) * 0.75 + 0.5);
  };
  return RGB(lighten(r), lighten(g), lighten(b));
}

// 分层窗口内容面(PARGB 位图),尺寸变化时重建。
bool EnsureSurface(int w, int h) {
  if (g_surface && g_gfx) {
    if (g_surface->GetWidth() == static_cast<UINT>(w) &&
        g_surface->GetHeight() == static_cast<UINT>(h)) {
      return true;
    }
    delete g_gfx;
    delete g_surface;
    g_gfx = nullptr;
    g_surface = nullptr;
  }
  g_surface = new gd::Bitmap(w, h, PixelFormat32bppPARGB);
  if (g_surface->GetLastStatus() != gd::Ok) {
    delete g_surface;
    g_surface = nullptr;
    return false;
  }
  g_gfx = gd::Graphics::FromImage(g_surface);
  if (!g_gfx) {
    delete g_surface;
    g_surface = nullptr;
    return false;
  }
  return true;
}

// 渲染整窗内容并经 UpdateLayeredWindow 上屏(逐像素 alpha):
// - 未悬停:无任何底板,只有 alpha=1 的隐形命中层撑起歌词区矩形,
//   保证可拖动/可触发悬停;其余区域 alpha=0 透明且不接收鼠标。
// - 悬停:整栏灰色半透明圆角面板 + 按钮。
void RenderLayered() {
  if (!g_hwnd || !EnsureSurface(g_curWidth, TotalHeight())) return;
  gd::Graphics& g = *g_gfx;
  g.SetSmoothingMode(gd::SmoothingModeAntiAlias);
  g.SetTextRenderingHint(gd::TextRenderingHintAntiAliasGridFit);
  g.Clear(gd::Color(0, 0, 0, 0));

  const REAL w = static_cast<REAL>(g_curWidth);
  const REAL baseY = static_cast<REAL>(g_popupH);
  const REAL hLyric = static_cast<REAL>(g_curHeight);
  const REAL rad = static_cast<REAL>(S(kCornerRadius));
  // 底板两态:未悬停 alpha=1(隐形但接收鼠标),悬停灰色半透明。
  if (g_hovering) {
    FillRoundRect(g, 0, baseY, w, hLyric, rad,
                  Gd(kHoverPanelColor, kHoverPanelAlpha));
  } else {
    FillRoundRect(g, 0, baseY, w, hLyric, rad, gd::Color(1, 255, 255, 255));
  }

  // 两行文字:标题行(歌名 - 歌手) + 歌词行(空则 MusicFlow),描边字。
  const std::wstring header =
      g_artist.empty() ? g_song : (g_song + L" - " + g_artist);
  const std::wstring lyric = g_lyric.empty() ? L"MusicFlow" : g_lyric;
  DrawOutlinedText(g, header, g_famUI, gd::FontStyleRegular,
                   Sf(kHeaderFontSize), static_cast<REAL>(g_padX),
                   baseY + hLyric * 0.20f, Gd(kHeaderFillColor),
                   Gd(kHeaderStrokeColor), Sf(kHeaderStrokeW) * 0.5f);
  DrawOutlinedText(g, lyric, g_famUI, gd::FontStyleBold, Sf(kLyricFontSize),
                   static_cast<REAL>(g_padX), baseY + hLyric * 0.66f,
                   Gd(g_lyricColor), Gd(ComputeLyricStrokeColor(g_lyricColor)),
                   Sf(kLyricStrokeW) * 0.5f);

  // 悬停时:按钮;弹窗展开时:音量面板。
  if (g_hovering) {
    for (int i = 0; i < 6; ++i) DrawButton(g, i);
  }
  DrawVolumePopup(g);

  // 上屏:UpdateLayeredWindow(ptDst=nullptr 保持当前位置)。
  HBITMAP hbmp = nullptr;
  if (g_surface->GetHBITMAP(gd::Color(0, 0, 0, 0), &hbmp) != gd::Ok || !hbmp) {
    if (hbmp) DeleteObject(hbmp);
    return;
  }
  HDC hdcScreen = GetDC(nullptr);
  HDC mem = CreateCompatibleDC(hdcScreen);
  if (!mem) {
    DeleteObject(hbmp);
    ReleaseDC(nullptr, hdcScreen);
    return;
  }
  HBITMAP old = static_cast<HBITMAP>(SelectObject(mem, hbmp));
  POINT src{0, 0};
  SIZE sz{g_curWidth, TotalHeight()};
  BLENDFUNCTION bf{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
  UpdateLayeredWindow(g_hwnd, hdcScreen, nullptr, &sz, mem, &src, 0, &bf,
                      ULW_ALPHA);
  SelectObject(mem, old);
  DeleteObject(hbmp);
  DeleteDC(mem);
  ReleaseDC(nullptr, hdcScreen);
}

void RepaintLyric() { RenderLayered(); }

void SetPopupOpen(bool open) {
  if (g_popupOpen == open) return;
  g_popupOpen = open;
  if (!open) g_sliderDragging = false;
  RepaintLyric();
}

LRESULT CALLBACK LyricWndProc(HWND hwnd, UINT message, WPARAM wParam,
                              LPARAM lParam) {
  switch (message) {
    case WM_PAINT: {
      // 分层窗口由 UpdateLayeredWindow 呈现,不产生有效绘制;
      // 仅为平衡校验区域。
      PAINTSTRUCT ps;
      BeginPaint(hwnd, &ps);
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
      RepaintLyric();
      return 0;
    }
    default:
      return DefWindowProcW(hwnd, message, wParam, lParam);
  }
}

}  // namespace

void DesktopLyricInit(HINSTANCE instance) {
  if (g_hwnd) return;
  if (g_gdiplusToken == 0) {
    gd::GdiplusStartupInput input;
    gd::GdiplusStartup(&g_gdiplusToken, &input, nullptr);
    g_famUI = new gd::FontFamily(L"Microsoft YaHei UI");
    g_famIcon = new gd::FontFamily(L"Segoe MDL2 Assets");
    ApplyDpiScale(96);
  }

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
  const auto getDpiForWindow =
      reinterpret_cast<UINT(WINAPI*)(HWND)>(
          GetProcAddress(GetModuleHandleW(L"user32.dll"), "GetDpiForWindow"));
  if (getDpiForWindow) {
    ApplyDpiScale(static_cast<int>(getDpiForWindow(g_hwnd)));
  }
  RepaintLyric();
}

void DesktopLyricSetEventCallback(DesktopLyricEventCallback callback) {
  g_eventCb = callback;
}

void DesktopLyricUpdateState(const DesktopLyricState& state) {
  const bool changed = g_song != state.song || g_artist != state.artist ||
                       g_lyric != state.lyric || g_playing != state.playing ||
                       g_liked != state.liked || g_mode != state.mode ||
                       g_lyricColor != state.lyricColor ||
                       std::fabs(g_volume - state.volume) > 0.004;
  g_song = state.song;
  g_artist = state.artist;
  g_lyric = state.lyric;
  g_playing = state.playing;
  g_liked = state.liked;
  g_mode = state.mode;
  g_lyricColor = state.lyricColor;
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
    RepaintLyric();
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
  delete g_gfx;
  g_gfx = nullptr;
  delete g_surface;
  g_surface = nullptr;
  delete g_fontPopup;
  g_fontPopup = nullptr;
  delete g_fontIcon;
  g_fontIcon = nullptr;
  delete g_fontIconPlay;
  g_fontIconPlay = nullptr;
  delete g_famUI;
  g_famUI = nullptr;
  delete g_famIcon;
  g_famIcon = nullptr;
  if (g_gdiplusToken != 0) {
    gd::GdiplusShutdown(g_gdiplusToken);
    g_gdiplusToken = 0;
  }
}

