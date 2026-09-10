#include "desktop_lyric.h"
#include "desktop_lyric_logic.h"  // 纯逻辑(描边色/跑马灯/单击阈值),有独立单测

#include <windowsx.h>
#include <objidl.h>
#include <gdiplus.h>

#include <algorithm>
#include <atomic>
#include <cfloat>
#include <cmath>
#include <string>
#include <vector>

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
constexpr int kWindowWidth = 572;     // 窗口固定宽度
// 宽度 520 -> 572(2026-09-10):悬停按钮栏新增「切换播放器」后共 8 个按钮,
// 最左的 kOffPrev 从 351 推到 403, 窗口同步加宽保证文字区不被挤占。
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
constexpr COLORREF kLyricFillColor = RGB(255, 194, 51);   // 歌词填充固定暖黄(0xFFC233)
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
constexpr COLORREF kOffColor = RGB(104, 108, 118);    // 置灰(不可用)
constexpr COLORREF kTrackColor = RGB(58, 61, 69);     // 滑条槽
constexpr COLORREF kTrackFill = RGB(55, 138, 221);    // 滑条已填充(蓝)
constexpr COLORREF kThumbColor = RGB(255, 255, 255);  // 滑块

// 按钮(圆心,逻辑坐标,自右缘向左排;窗口宽 W,歌词区高 84,中线 y=弹窗高+42):
// 上一首 / 播放暂停(大) / 下一首 / 播放模式 / 喜欢 / 播放队列 /
// 音量(滑条弹窗) / 切换播放器(最贴边,紧挨音量右侧)
constexpr int kBtnR = 17;             // 普通按钮半径
constexpr int kPlayR = 22;            // 播放按钮半径
// 圆心相对右缘的偏移(逻辑 px): volume=35(最右), switch=87, queue=139,
// like=191, mode=243, next=295, play=349, prev=403
// 注意:切换播放器(switch)必须紧挨音量(volume)右侧 —— 用户 2026-09-10 明确
// 要求「基站图标放在音量的右边」,即 switch 的偏移要比 volume 更靠右(更小)。
constexpr int kOffSwitch = 35;   // 最右:切换播放器
constexpr int kOffVolume = 87;   // 音量(滑条弹窗)
constexpr int kOffQueue = 139;
constexpr int kOffLike = 191;
constexpr int kOffMode = 243;
constexpr int kOffNext = 295;
constexpr int kOffPlay = 349;
constexpr int kOffPrev = 403;

// 按钮索引(与 ButtonGeom / 命中测试 / 点击派发共用,避免魔法数字错位)。
constexpr int kBtnIdxPrev = 0;
constexpr int kBtnIdxPlay = 1;
constexpr int kBtnIdxNext = 2;
constexpr int kBtnIdxMode = 3;
constexpr int kBtnIdxVolume = 4;
constexpr int kBtnIdxLike = 5;
constexpr int kBtnIdxQueue = 6;
constexpr int kBtnIdxSwitch = 7;
constexpr int kBtnCount = 8;

// 队列弹窗(逻辑 px):行高、最大可见行数与内边距。
constexpr int kQueueRowH = 32;
constexpr int kQueueMaxRows = 7;
constexpr int kListPopupPadV = 10;    // 列表弹窗上下内边距
constexpr int kListPopupPadH = 8;     // 列表弹窗左右外边距
// 列表弹窗面板上下「外」边距(ListPanelRect/SwitchPanelRect 的 top/bottom 6px)。
// **必须与 PopupLogicalHeight 的高度公式一致**:公式若只算 padV 不算这 6px,
// 行区(ListRowsRect 在面板基础上再收 padV)会比可用高度多出 2*S(6),
// 最后一行永远被 `rowTop + rowH > rows.bottom` 裁掉 —— 2026-09-10「设备列表
// 只显示本机」的真实根因(主卧恒为最后一行,恒被裁;队列弹窗同样中招)。
constexpr int kListPopupMarginV = 6;
constexpr int kListRowPadX = 14;      // 行内左右留白
constexpr int kListRowGap = 6;        // 行与行之间的间隙

// 「切换播放器」弹窗(逻辑 px):比队列弹窗略高的行(要放两行文字:
// 设备名 + 状态副标题),宽度对齐 MINI 播放条小弹窗的 320。
constexpr int kSwitchRowH = 42;
constexpr int kSwitchMaxRows = 6;
constexpr int kSwitchPanelW = 300;

// 设备行内的「接续」箭头(↓ 接回本机 / ↑ 推到该设备):与 MINI 播放条
// 小弹窗 PeerCastRow 的 _HandoffButton 同语义,只在该设备真有「现场」可搬
// 时才出现(由 Flutter 侧 canPull/canPush 决定)。从行右缘向左排,先 ↓ 后 ↑。
constexpr int kHandoffR = 11;      // 箭头按钮半径(逻辑 px)
constexpr int kHandoffGap = 2;     // 两支之间的间隙
constexpr int kHandoffPadR = 2;    // 最右一支到行右缘的距离
constexpr int kHandoffPadL = 6;    // 文本区与箭头区之间的留白
constexpr int kHandoffEm = 14;     // 箭头字号(逻辑 px)

// 设备类型小徽章(DLNA / 群组…):跟设备名同行、紧贴其后。
constexpr int kBadgeFontSize = 9;  // 徽章字号(比正文小一号)
constexpr int kBadgePadX = 4;      // 徽章左右内边距
constexpr int kBadgePadY = 1;      // 徽章上下内边距
constexpr int kBadgeGap = 5;       // 徽章与设备名之间的间隙

// 播放模式(与 Dart 歌词窗模式串对齐: 0=shuffle,1=repeatAll,2=repeatOne,
// 3=order 顺序播放)
constexpr int kModeShuffle = 0;
constexpr int kModeRepeatAll = 1;
constexpr int kModeRepeatOne = 2;
constexpr int kModeOrder = 3;

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
// 播放队列与顺序播放(order)按钮:与 MINI 播放器同款 remixicon 字形,
// 轮廓离线提取后硬编码(见 DrawRemixGlyph 处注释),无需字符码点常量。

HWND g_hwnd = nullptr;
ULONG_PTR g_gdiplusToken = 0;
gd::FontFamily* g_famUI = nullptr;    // Microsoft YaHei UI
gd::FontFamily* g_famIcon = nullptr;  // Segoe MDL2 Assets
gd::Font* g_fontPopup = nullptr;      // 弹窗文本(百分比/列表行)
gd::Font* g_fontIcon = nullptr;       // 普通按钮图标
gd::Font* g_fontIconPlay = nullptr;   // 播放按钮图标(大一号)
gd::Font* g_fontBadge = nullptr;      // 设备类型小徽章(DLNA/群组…)
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
bool g_pressPending = false;   // 按下未判定:未超阈值=单击(开关主窗口),超了=拖动
POINT g_pressPt{};             // 按下时的客户区坐标(拖动偏移基准/单击判定)
bool g_hovering = false;       // 鼠标是否在窗口内(决定面板/按钮显示)
bool g_sliderDragging = false; // 正在拖音量滑条
int g_hotButton = -1;          // 悬停按钮索引
int g_pressedButton = -1;      // 按下中的按钮索引
POINT g_dragOffset{};

// ---- 弹窗(同一时间最多展开一个,展开时窗口向上增高) ----
// Switch:桌面歌词自己的「切换播放器」弹窗(内容与 MINI 播放条的小弹窗一致,
// 由 Flutter 组好设备行文本推送过来)。它在歌词窗上方展开,而不是回到主窗口
// 弹——用户 2026-09-10 明确要求「弹窗不是在主窗口弹,是在桌面歌词上面新增一个
// 弹窗,里面的内容和 MINI 弹窗一样」。
enum class PopupKind { None, Volume, Queue, Switch };
PopupKind g_popup = PopupKind::None;
// 播放队列弹窗数据(Flutter 推送,全量替换)。
std::vector<std::wstring> g_queueItems;
int g_queueIndex = -1;
int g_queueScroll = 0;  // 顶部可见行下标(滚轮滚动)
int g_hotRow = -1;  // 悬停中的列表行(面板内高亮)

// 「切换播放器」弹窗数据(Flutter 推送,全量替换):每行 = 设备名,
// cur 标记当前控制目标(高亮);可选副标题(状态文案)。
// badge = 设备类型小徽章文本(本机行空);canPull/canPush 决定行右侧的
// 两支接续箭头(见 kHandoffR 处注释,语义与 MINI 弹窗 PeerCastRow 一致)。
struct LyricSwitchItem {
  std::wstring title;
  std::wstring subtitle;
  std::wstring badge;
  bool current = false;
  bool canPull = false;
  bool canPush = false;
  bool handoff = false;
  bool isRefresh = false;  // 「刷新设备列表」行(无徽章/箭头/选中语义)
  int icon = 0;            // 行首图标(1=耳机 2=基站 3=人群 4=刷新 0=圆点)
};
std::vector<LyricSwitchItem> g_switchItems;
int g_switchScroll = 0;  // 切换弹窗顶部可见行下标(滚轮滚动)
bool g_switchLoading = false;  // 正在拉取设备列表(显示「加载中…」)
int g_hotSwitchAction = -1;  // 悬停中的行内接续箭头:0=↓拉 1=↑推,-1=无
int g_hotSwitchRow = -1;     // 该箭头所属行(仅 g_hotSwitchAction>=0 时有效)

// ---- 歌词跑马灯滚动(超宽时从右向左匀速滚,首尾各停 1.8s,循环) ----
constexpr UINT_PTR kScrollTimerId = 1;
constexpr ULONGLONG kScrollHoldMs = 1800;  // 起点终点停留
constexpr int kScrollSpeed = 40;           // 滚动速度(逻辑 px/s)
constexpr int kScrollTimerMs = 33;         // 定时器周期(约 30fps)
double g_lyricOverflow = 0;                // 歌词超出可用宽度(物理 px,<=0 不滚)
ULONGLONG g_scrollCycle = 0;               // 本轮循环起点 tick,0=待重置
bool g_scrollTimerOn = false;

// ---- 悬停状态轮询(独立线程,不依赖 WM_MOUSELEAVE/WM_TIMER) ----
// 分层窗按像素 alpha 命中:歌词笔画间隙/窗口几何变化都会误发或漏发
// WM_MOUSELEAVE;事件驱动 + 重登记复核又会与系统互相触发形成消息风暴
// (v4.3.22 卡顿根因)。而 WM_TIMER 是最低优先级消息,只在主线程消息
// 队列完全空闲时才投递——debug 联调时 Flutter 把平台线程塞满,定时器
// 会被饿死(悬停滞后/移出后高亮不消)。故用独立线程轮询光标,检测到
// 进出/移动后 PostMessage 唤醒主线程重算(普通队列消息不会被饿死)。
constexpr UINT kHoverWakeMsg = WM_APP + 0x51;
constexpr int kHoverPollMs = 20;
std::atomic<bool> g_hoverRun{false};
HANDLE g_hoverExitEvt = nullptr;  // 悬停轮询线程的协作退出事件
HANDLE g_hoverThread = nullptr;
POINT g_lastPollPt{};       // 仅轮询线程读写
bool g_lastPollInside = false;

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

// 悬停判定的客户区 y 下限:弹窗未展开时从歌词区顶(g_popupH)算起——上方
// 弹窗区 alpha=0 不接收系统鼠标,轮询/即时高亮也必须同样忽略,否则鼠标
// 掠过歌词上方空白区会误点亮整条悬停高亮;弹窗展开时整窗可停留(离开即收起)。
// 轮询线程(HoverPollProc)与主线程(UpdateHoverState/WM_MOUSEMOVE)共用,
// 保证「唤醒判定」与「状态判定」同规则。
int HoverTopLimit() { return g_popup == PopupKind::None ? g_popupH : 0; }

// GDI+ COLORREF → Color(COLoRREF 布局 0x00bbggrr;不用 GetXValue 宏,
// 对 constexpr 截断会触发 C4310)。
gd::Color Gd(COLORREF c, int alpha = 255) {
  return gd::Color(static_cast<BYTE>(alpha), static_cast<BYTE>(c & 0xFF),
                   static_cast<BYTE>((c >> 8) & 0xFF),
                   static_cast<BYTE>((c >> 16) & 0xFF));
}

// 按钮几何:圆心(物理 px)与半径。
// idx: 0=prev 1=play 2=next 3=mode 4=volume 5=like 6=queue 7=switch_player
// (7=switch 为最右侧,紧挨音量右侧;见 kOffSwitch/kOffVolume 注释)
struct BtnGeom {
  int cx, cy, r;
};

BtnGeom ButtonGeom(int idx) {
  const int w = g_curWidth;
  const int cy = g_popupH + g_curHeight / 2;
  switch (idx) {
    case kBtnIdxPrev: return {w - S(kOffPrev), cy, S(kBtnR)};
    case kBtnIdxPlay: return {w - S(kOffPlay), cy, S(kPlayR)};
    case kBtnIdxNext: return {w - S(kOffNext), cy, S(kBtnR)};
    case kBtnIdxMode: return {w - S(kOffMode), cy, S(kBtnR)};
    case kBtnIdxVolume: return {w - S(kOffVolume), cy, S(kBtnR)};
    case kBtnIdxLike: return {w - S(kOffLike), cy, S(kBtnR)};
    case kBtnIdxSwitch: return {w - S(kOffSwitch), cy, S(kBtnR)};
    default: return {w - S(kOffQueue), cy, S(kBtnR)};
  }
}

// 各弹窗的逻辑高度(未展开=音量弹窗高度,窗口几何与旧版一致;
// 列表弹窗高度随行数自适应)。
int PopupLogicalHeight(PopupKind kind) {
  switch (kind) {
    case PopupKind::Queue: {
      const int rows =
          std::max(1, std::min<int>(static_cast<int>(g_queueItems.size()),
                                    kQueueMaxRows));
      return rows * kQueueRowH + (rows - 1) * kListRowGap +
             kListPopupPadV * 2 + kListPopupMarginV * 2;
    }
    case PopupKind::Switch: {
      // 与 Queue 同一套内边距,但行更高(两行文字:设备名 + 状态副标题)。
      // 设备数为 0 时也要占一行,用于显示「正在加载…/无可用设备」提示。
      const int rows = std::max(
          1, std::min<int>(static_cast<int>(g_switchItems.size()),
                           kSwitchMaxRows));
      return rows * kSwitchRowH + (rows - 1) * kListRowGap +
             kListPopupPadV * 2 + kListPopupMarginV * 2;
    }
    default:
      return kPopupHeight;
  }
}

// 音量弹窗面板(物理 px),位于窗口顶部弹窗区。
RECT VolumePanelRect() {
  const int volCx = g_curWidth - S(kOffVolume);
  RECT rc{};
  rc.left = volCx - S(32);
  rc.right = volCx + S(32);
  rc.top = S(8);
  rc.bottom = g_popupH - S(8);
  return rc;
}

// 队列/设备列表弹窗面板(物理 px):横向铺满歌词窗(留边),向上增高。
RECT ListPanelRect() {
  RECT rc{};
  rc.left = S(kListPopupPadH);
  rc.right = g_curWidth - S(kListPopupPadH);
  rc.top = S(kListPopupMarginV);
  rc.bottom = g_popupH - S(kListPopupMarginV);
  return rc;
}

// 「切换播放器」面板:锚定在切换按钮(最右)下方,比列表弹窗窄一些,
// 呈现成一张从右缘探出的小卡(与 MINI 播放条的 320px 小弹窗观感一致)。
//
// 注意:这里必须写 std::min<int>/std::max<int> 显式指定类型——
// S() 返回 int,而 RECT 的 left/right 是 LONG(×64 为 long long)是
// **不同类型**,std::max(a, b) 的模板推导会因此失败:
//   error C2672: "std::max": 未找到匹配的重载函数
// (cl /Zs 只做语法检查、不实例化模板,所以本地 check_native_syntax.sh
// 查不出来,只有真正 build windows 才会炸——2026-09-10 实测踩过。)
RECT SwitchPanelRect() {
  const int btnCx = g_curWidth - S(kOffSwitch);
  RECT rc{};
  rc.right = std::min<int>(
      g_curWidth - S(kListPopupPadH), btnCx + S(kSwitchPanelW / 2));
  rc.left = std::max<int>(S(kListPopupPadH), rc.right - S(kSwitchPanelW));
  rc.top = S(kListPopupMarginV);
  rc.bottom = g_popupH - S(kListPopupMarginV);
  return rc;
}

RECT PopupPanelRect() {
  switch (g_popup) {
    case PopupKind::Volume: return VolumePanelRect();
    case PopupKind::Switch: return SwitchPanelRect();
    default: return ListPanelRect();
  }
}

// 滑条轨道(物理 px)。
RECT TrackRect() {
  const int volCx = g_curWidth - S(kOffVolume);
  const RECT panel = VolumePanelRect();
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
  for (int i = kBtnCount - 1; i >= 0; --i) {
    if (PtInCircle(pt, ButtonGeom(i))) return i;
  }
  return -1;
}

bool PtInPanel(const POINT& pt) {
  if (g_popup == PopupKind::None) return false;
  const RECT rc = PopupPanelRect();
  return pt.x >= rc.left && pt.x < rc.right && pt.y >= rc.top &&
         pt.y < rc.bottom;
}

// 列表弹窗行区(面板内减去上下内边距,物理 px)。
// 切换弹窗复用同一几何(同一套内边距),只是面板矩形不同。
RECT ListRowsRect() {
  const RECT panel = PopupPanelRect();
  RECT rc{};
  rc.left = panel.left + S(kListRowPadX);
  rc.right = panel.right - S(kListRowPadX);
  rc.top = panel.top + S(kListPopupPadV);
  rc.bottom = panel.bottom - S(kListPopupPadV);
  return rc;
}

// 当前展开的列表弹窗是否属于「可滚动列表」类(队列 / 切换播放器)。
// 两者的滚动基准(q_queueScroll / q_switchScroll)与行高不同,由下面
// 几个取值函数统一分派,避免每个调用点各写一遍 if。
bool PopupIsListLike() {
  return g_popup == PopupKind::Queue || g_popup == PopupKind::Switch;
}

// 当前列表弹窗的行高(物理 px)。
int ListRowH() {
  return S(g_popup == PopupKind::Switch ? kSwitchRowH : kQueueRowH);
}

int ListRowGap() { return S(kListRowGap); }

// 当前列表弹窗的数据行数 / 顶部滚动下标 / 最大可见行数。
int ListItemCount() {
  return g_popup == PopupKind::Switch
             ? static_cast<int>(g_switchItems.size())
             : static_cast<int>(g_queueItems.size());
}

int& ListScroll() {
  return g_popup == PopupKind::Switch ? g_switchScroll : g_queueScroll;
}

int ListMaxRows() {
  return g_popup == PopupKind::Switch ? kSwitchMaxRows : kQueueMaxRows;
}

int ListVisibleRows() {
  const RECT rows = ListRowsRect();
  const int slot = ListRowH() + ListRowGap();
  int n = (rows.bottom - rows.top + ListRowGap()) / slot;
  return std::max(1, n);
}

// 列表行命中:返回全局行下标,不在行上返回 -1。
int HitTestListRow(const POINT& pt) {
  if (!PopupIsListLike()) return -1;
  const RECT rows = ListRowsRect();
  if (pt.x < rows.left || pt.x >= rows.right || pt.y < rows.top ||
      pt.y >= rows.bottom) {
    return -1;
  }
  const int slot = ListRowH() + ListRowGap();
  const int idx = ListScroll() + (pt.y - rows.top) / slot;
  const int count = ListItemCount();
  if (idx < 0 || idx >= count) return -1;
  // 命中落进行间空隙时不算。
  const int inSlot = static_cast<int>(pt.y - rows.top) % slot;
  if (inSlot >= ListRowH()) return -1;
  return idx;
}

// ---- 设备行内的「接续」箭头(↓ 接回本机 / ↑ 推到该设备) ----
// 语义与 MINI 播放条小弹窗 PeerCastRow 的 _HandoffButton 完全一致:
// 一支只画粗箭头,可用时点亮(歌词色),无「现场」可搬时置灰。

// 箭头按钮圆心 x(物理 px)。which: 0=↓(接回本机,靠左) 1=↑(推到设备,靠右)。
// 与 MINI 弹窗 PeerCastRow 的 Row 顺序一致:先 ↓ 后 ↑(↓ 在左、↑ 在右)。
// 2026-09-10 用户反馈画反了(之前 which=0 落在靠右位置)。
int HandoffCx(const RECT& rows, int which) {
  const int r = S(kHandoffR);
  return rows.right - S(kHandoffPadR) - r -
         (1 - which) * (2 * r + S(kHandoffGap));
}

// 箭头圆心 y / 半径(物理 px)。
int HandoffCy(int rowTop) { return rowTop + ListRowH() / 2; }
int HandoffRadius() { return S(kHandoffR); }

// 整块箭头区占的宽度(物理 px,含与文本区之间的留白):没箭头则为 0。
int HandoffAreaW(const LyricSwitchItem& item) {
  if (!item.handoff) return 0;
  const int r = S(kHandoffR);
  return S(kHandoffPadR) + 4 * r + S(kHandoffGap) + S(kHandoffPadL);
}

// 行内接续箭头命中:命中返回 0=↓ 接回本机 / 1=↑ 推到该设备,未命中 -1。
// rowIndex 输出所命中的全局行下标(仅返回非 -1 时有效)。
// 用方形命中区而非圆形:目标只有 22px,方形更好点。
int HitTestSwitchHandoff(const POINT& pt, int* rowIndex) {
  if (g_popup != PopupKind::Switch) return -1;
  const int row = HitTestListRow(pt);
  if (row < 0 || row >= static_cast<int>(g_switchItems.size())) return -1;
  const LyricSwitchItem& item = g_switchItems[row];
  if (!item.handoff) return -1;
  const RECT rows = ListRowsRect();
  const int slot = ListRowH() + ListRowGap();
  const int rowTop = rows.top + (row - ListScroll()) * slot;
  const int r = HandoffRadius();
  const int dy = pt.y - HandoffCy(rowTop);
  if (dy < -r || dy > r) return -1;
  for (int which = 1; which >= 0; --which) {
    if (which == 0 && !item.canPull) continue;
    if (which == 1 && !item.canPush) continue;
    const int dx = pt.x - HandoffCx(rows, which);
    if (dx >= -r && dx <= r) {
      if (rowIndex) *rowIndex = row;
      return which;
    }
  }
  return -1;
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
  delete g_fontBadge;
  g_fontPopup =
      new gd::Font(g_famUI, Sf(kPopupFontSize), gd::FontStyleRegular,
                   gd::UnitPixel);
  g_fontIcon = new gd::Font(g_famIcon, Sf(20), gd::FontStyleRegular,
                            gd::UnitPixel);
  g_fontIconPlay = new gd::Font(g_famIcon, Sf(26), gd::FontStyleRegular,
                                gd::UnitPixel);
  g_fontBadge = new gd::Font(g_famUI, Sf(kBadgeFontSize), gd::FontStyleRegular,
                             gd::UnitPixel);
  g_curWidth = S(kWindowWidth);
  g_curHeight = S(kWindowHeight);
  g_padX = S(kPaddingX);
  g_popupH = S(PopupLogicalHeight(g_popup));
  g_scrollCycle = 0;  // 宽度变了,滚动按新宽度从头算
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

// ---- 硬编码 remixicon 字形 ----
// 队列与顺序播放(order)两枚图标要与 MINI 播放器同款(remixicon)。运行时
// 加载字体两条路都走不通:AddFontResourceExW(FR_PRIVATE) 只对 GDI TextOut
// 可见,GDI+ FontFamily 查不到(status 14);PrivateFontCollection 在本机
// 旧版 gdiplus(10.0.19041)上,集合内 family 首次进入
// GraphicsPath::AddString 即 c0000005 崩溃。故用 tool/gen_lyric_glyphs.py
// 离线从随包 remix.ttf 提取轮廓(upm=1200)硬编码:二次贝塞尔已升为三次,
// Y 已翻转为向下为正。字体随包固定、字形不变,一次提取永久有效,且与
// Flutter 端渲染同字体同源。
struct GlyphPt {
  float x, y;
};
struct RemixGlyphDef {
  const GlyphPt* pts;
  const BYTE* types;
  int count;
};

// ---- 硬编码 remixicon 字形轮廓(由 tool/gen_lyric_glyphs.py 生成, upm=1200, Y 已翻转为向下为正) ----
// U+F00D play_list_2_line (play-list-2-line): 5 contours, 18 points, ink bbox x[100..1100] y[-833..-8]
static const GlyphPt kRemixQueuePts[] = {
    {1100.0f,-108.0f}, {1100.0f,-8.0f}, {100.0f,-8.0f}, {100.0f,-108.0f}, {100.0f,-833.0f},
    {500.0f,-583.0f}, {100.0f,-333.0f}, {1100.0f,-458.0f}, {1100.0f,-358.0f}, {600.0f,-358.0f},
    {600.0f,-458.0f}, {200.0f,-652.0f}, {200.0f,-513.0f}, {311.0f,-583.0f}, {1100.0f,-808.0f},
    {1100.0f,-708.0f}, {600.0f,-708.0f}, {600.0f,-808.0f},
};
static const BYTE kRemixQueueTypes[] = {
    0x00, 0x01, 0x01, 0x81, 0x00, 0x01, 0x81, 0x00, 0x01, 0x01, 0x81, 0x00, 0x01, 0x81, 0x00,
    0x01, 0x01, 0x81,
};
static const RemixGlyphDef kRemixQueue{
    kRemixQueuePts, kRemixQueueTypes, 18};
// ops: {'moveTo': 5, 'lineTo': 13, 'closePath': 5}
// U+F399 list_ordered_2 (list-ordered-2): 5 contours, 68 points, ink bbox x[147..1053] y[-833..-8]
static const GlyphPt kRemixOrderPts[] = {
    {291.0f,-833.0f}, {239.0f,-833.0f}, {166.0f,-813.0f}, {166.0f,-735.0f}, {216.0f,-749.0f},
    {216.0f,-583.0f}, {153.0f,-583.0f}, {153.0f,-508.0f}, {353.0f,-508.0f}, {353.0f,-583.0f},
    {291.0f,-583.0f}, {503.0f,-808.0f}, {1053.0f,-808.0f}, {1053.0f,-708.0f}, {503.0f,-708.0f},
    {503.0f,-458.0f}, {1053.0f,-458.0f}, {1053.0f,-358.0f}, {503.0f,-358.0f}, {503.0f,-108.0f},
    {1053.0f,-108.0f}, {1053.0f,-8.0f}, {503.0f,-8.0f}, {147.0f,-226.0f}, {147.0f,-245.33f},
    {151.67f,-263.17f}, {161.0f,-279.5f}, {170.33f,-295.83f}, {183.17f,-308.67f},
    {199.5f,-318.0f}, {215.83f,-327.33f}, {233.67f,-332.17f}, {253.0f,-332.5f},
    {272.33f,-332.83f}, {290.17f,-328.17f}, {306.5f,-318.5f}, {322.83f,-308.83f},
    {335.67f,-295.83f}, {345.0f,-279.5f}, {354.33f,-263.17f}, {359.0f,-245.33f},
    {359.0f,-226.0f}, {359.0f,-202.0f}, {351.67f,-180.67f}, {337.0f,-162.0f}, {269.0f,-83.0f},
    {353.0f,-83.0f}, {353.0f,-8.0f}, {153.0f,-8.0f}, {153.0f,-64.0f}, {277.0f,-206.0f},
    {281.67f,-212.0f}, {284.0f,-219.0f}, {284.0f,-227.0f}, {284.0f,-235.0f}, {281.0f,-242.17f},
    {275.0f,-248.5f}, {269.0f,-254.83f}, {261.83f,-258.0f}, {253.5f,-258.0f}, {245.17f,-258.0f},
    {238.0f,-255.17f}, {232.0f,-249.5f}, {226.0f,-243.83f}, {222.67f,-237.0f}, {222.0f,-229.0f},
    {221.0f,-214.0f}, {147.0f,-214.0f},
};
static const BYTE kRemixOrderTypes[] = {
    0x00, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x81, 0x00, 0x01, 0x01, 0x81,
    0x00, 0x01, 0x01, 0x81, 0x00, 0x01, 0x01, 0x81, 0x00, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
    0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
    0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
    0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x01, 0x81,
};
static const RemixGlyphDef kRemixOrder{
    kRemixOrderPts, kRemixOrderTypes, 68};
// ops: {'moveTo': 5, 'lineTo': 27, 'closePath': 5, 'qCurveTo': 3}
// U+EAA6 base_station_line (base-station-line): 7 contours, 113 points, ink bbox x[119..1080] y[-900..60]
static const GlyphPt kRemixSwitchPlayerPts[] = {
    {600.0f,-390.0f}, {900.0f,60.0f}, {300.0f,60.0f}, {600.0f,-210.0f}, {487.0f,-40.0f},
    {713.0f,-40.0f}, {547.0f,-512.0f}, {532.33f,-526.0f}, {525.0f,-543.5f}, {525.0f,-564.5f},
    {525.0f,-585.5f}, {532.33f,-603.33f}, {547.0f,-618.0f}, {561.67f,-632.67f},
    {579.33f,-640.0f}, {600.0f,-640.0f}, {620.67f,-640.0f}, {638.33f,-632.67f},
    {653.0f,-618.0f}, {667.67f,-603.33f}, {675.0f,-585.5f}, {675.0f,-564.5f}, {675.0f,-543.5f},
    {667.67f,-525.83f}, {653.0f,-511.5f}, {638.33f,-497.17f}, {620.67f,-490.0f},
    {600.0f,-490.0f}, {579.33f,-490.0f}, {561.67f,-497.33f}, {547.0f,-512.0f}, {264.0f,-900.0f},
    {335.0f,-830.0f}, {287.0f,-782.0f}, {254.33f,-725.33f}, {237.0f,-660.0f},
    {220.33f,-596.67f}, {220.33f,-533.0f}, {237.0f,-469.0f}, {254.33f,-403.67f},
    {287.0f,-347.0f}, {335.0f,-299.0f}, {264.0f,-229.0f}, {203.33f,-289.67f}, {162.0f,-361.33f},
    {140.0f,-444.0f}, {119.33f,-524.67f}, {119.33f,-605.0f}, {140.0f,-685.0f},
    {162.0f,-767.67f}, {203.33f,-839.33f}, {264.0f,-900.0f}, {936.0f,-900.0f},
    {996.67f,-839.33f}, {1038.0f,-767.67f}, {1060.0f,-685.0f}, {1080.67f,-605.0f},
    {1080.67f,-524.67f}, {1060.0f,-444.0f}, {1038.0f,-361.33f}, {996.67f,-289.67f},
    {936.0f,-229.0f}, {865.0f,-299.0f}, {913.0f,-347.0f}, {945.67f,-403.67f}, {963.0f,-469.0f},
    {979.67f,-533.0f}, {979.67f,-596.67f}, {963.0f,-660.0f}, {945.67f,-725.33f},
    {913.0f,-782.0f}, {865.0f,-830.0f}, {406.0f,-759.0f}, {476.0f,-688.0f}, {454.0f,-666.0f},
    {439.0f,-640.0f}, {431.0f,-610.0f}, {423.0f,-580.0f}, {423.0f,-549.83f}, {431.0f,-519.5f},
    {439.0f,-489.17f}, {454.0f,-463.0f}, {476.0f,-441.0f}, {406.0f,-370.0f}, {370.67f,-405.33f},
    {346.83f,-446.67f}, {334.5f,-494.0f}, {322.17f,-541.33f}, {322.17f,-588.5f},
    {334.5f,-635.5f}, {346.83f,-682.5f}, {370.67f,-723.67f}, {406.0f,-759.0f}, {794.0f,-759.0f},
    {829.33f,-723.67f}, {853.17f,-682.5f}, {865.5f,-635.5f}, {877.83f,-588.5f},
    {877.83f,-541.33f}, {865.5f,-494.0f}, {853.17f,-446.67f}, {829.33f,-405.33f},
    {794.0f,-370.0f}, {724.0f,-441.0f}, {746.0f,-463.0f}, {761.0f,-489.17f}, {769.0f,-519.5f},
    {777.0f,-549.83f}, {777.0f,-580.0f}, {769.0f,-610.0f}, {761.0f,-640.0f}, {746.0f,-666.0f},
    {724.0f,-688.0f},
};
static const BYTE kRemixSwitchPlayerTypes[] = {
    0x00, 0x01, 0x81, 0x00, 0x01, 0x81, 0x00, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
    0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
    0x83, 0x00, 0x01, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x01, 0x03, 0x03,
    0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x83, 0x00, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
    0x03, 0x03, 0x01, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x83, 0x00, 0x01, 0x03,
    0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x01, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
    0x03, 0x03, 0x83, 0x00, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x01, 0x03,
    0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x83,
};
static const RemixGlyphDef kRemixSwitchPlayer{
    kRemixSwitchPlayerPts, kRemixSwitchPlayerTypes, 113};
// ops: {'moveTo': 7, 'lineTo': 10, 'closePath': 7, 'qCurveTo': 17}
// U+EE04 headphone_fill (headphone-fill): 1 contours, 105 points, ink bbox x[100..1100] y[-895..55]
static const GlyphPt kRemixHeadphonePts[] = {
    {200.0f,-395.0f}, {350.0f,-395.0f}, {368.0f,-395.0f}, {384.67f,-390.5f}, {400.0f,-381.5f},
    {415.33f,-372.5f}, {427.5f,-360.33f}, {436.5f,-345.0f}, {445.5f,-329.67f}, {450.0f,-313.0f},
    {450.0f,-295.0f}, {450.0f,-45.0f}, {450.0f,-27.0f}, {445.5f,-10.33f}, {436.5f,5.0f},
    {427.5f,20.33f}, {415.33f,32.5f}, {400.0f,41.5f}, {384.67f,50.5f}, {368.0f,55.0f},
    {350.0f,55.0f}, {200.0f,55.0f}, {182.0f,55.0f}, {165.33f,50.5f}, {150.0f,41.5f},
    {134.67f,32.5f}, {122.5f,20.33f}, {113.5f,5.0f}, {104.5f,-10.33f}, {100.0f,-27.0f},
    {100.0f,-45.0f}, {100.0f,-395.0f}, {100.0f,-463.0f}, {113.0f,-528.0f}, {139.0f,-590.0f},
    {164.33f,-649.33f}, {200.17f,-702.17f}, {246.5f,-748.5f}, {292.83f,-794.83f},
    {345.67f,-830.67f}, {405.0f,-856.0f}, {467.0f,-882.0f}, {532.0f,-895.0f}, {600.0f,-895.0f},
    {668.0f,-895.0f}, {733.0f,-882.0f}, {795.0f,-856.0f}, {854.33f,-830.67f},
    {907.17f,-794.83f}, {953.5f,-748.5f}, {999.83f,-702.17f}, {1035.67f,-649.33f},
    {1061.0f,-590.0f}, {1087.0f,-528.0f}, {1100.0f,-463.0f}, {1100.0f,-395.0f},
    {1100.0f,-45.0f}, {1100.0f,-27.0f}, {1095.5f,-10.33f}, {1086.5f,5.0f}, {1077.5f,20.33f},
    {1065.33f,32.5f}, {1050.0f,41.5f}, {1034.67f,50.5f}, {1018.0f,55.0f}, {1000.0f,55.0f},
    {850.0f,55.0f}, {832.0f,55.0f}, {815.33f,50.5f}, {800.0f,41.5f}, {784.67f,32.5f},
    {772.5f,20.33f}, {763.5f,5.0f}, {754.5f,-10.33f}, {750.0f,-27.0f}, {750.0f,-45.0f},
    {750.0f,-295.0f}, {750.0f,-313.0f}, {754.5f,-329.67f}, {763.5f,-345.0f}, {772.5f,-360.33f},
    {784.67f,-372.5f}, {800.0f,-381.5f}, {815.33f,-390.5f}, {832.0f,-395.0f}, {850.0f,-395.0f},
    {1000.0f,-395.0f}, {1000.0f,-467.67f}, {981.67f,-535.0f}, {945.0f,-597.0f},
    {909.67f,-657.0f}, {862.0f,-704.67f}, {802.0f,-740.0f}, {740.0f,-776.67f},
    {672.67f,-795.0f}, {600.0f,-795.0f}, {527.33f,-795.0f}, {460.0f,-776.67f}, {398.0f,-740.0f},
    {338.0f,-704.67f}, {290.33f,-657.0f}, {255.0f,-597.0f}, {218.33f,-535.0f},
    {200.0f,-467.67f}, {200.0f,-395.0f},
};
static const BYTE kRemixHeadphoneTypes[] = {
    0x00, 0x01, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x01, 0x03, 0x03, 0x03,
    0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x01, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
    0x03, 0x01, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
    0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x01, 0x03, 0x03, 0x03,
    0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x01, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
    0x03, 0x01, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x01, 0x03, 0x03, 0x03,
    0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x83,
};
static const RemixGlyphDef kRemixHeadphone{
    kRemixHeadphonePts, kRemixHeadphoneTypes, 105};
// ops: {'moveTo': 1, 'lineTo': 8, 'qCurveTo': 16, 'closePath': 1}
// U+F4E4 group_3_line (group-3-line): 8 contours, 233 points, ink bbox x[100..1100] y[-870..30]
static const GlyphPt kRemixGroupPts[] = {
    {425.0f,-670.0f}, {425.0f,-652.0f}, {420.5f,-635.33f}, {411.5f,-620.0f}, {402.5f,-604.67f},
    {390.33f,-592.5f}, {375.0f,-583.5f}, {359.67f,-574.5f}, {343.0f,-570.0f}, {325.0f,-570.0f},
    {307.0f,-570.0f}, {290.33f,-574.5f}, {275.0f,-583.5f}, {259.67f,-592.5f}, {247.5f,-604.67f},
    {238.5f,-620.0f}, {229.5f,-635.33f}, {225.0f,-652.0f}, {225.0f,-670.0f}, {225.0f,-688.0f},
    {229.5f,-704.67f}, {238.5f,-720.0f}, {247.5f,-735.33f}, {259.67f,-747.5f}, {275.0f,-756.5f},
    {290.33f,-765.5f}, {307.0f,-770.0f}, {325.0f,-770.0f}, {343.0f,-770.0f}, {359.67f,-765.5f},
    {375.0f,-756.5f}, {390.33f,-747.5f}, {402.5f,-735.33f}, {411.5f,-720.0f}, {420.5f,-704.67f},
    {425.0f,-688.0f}, {425.0f,-670.0f}, {125.0f,-670.0f}, {125.0f,-634.0f}, {134.0f,-600.67f},
    {152.0f,-570.0f}, {170.0f,-539.33f}, {194.33f,-515.0f}, {225.0f,-497.0f}, {255.67f,-479.0f},
    {289.0f,-470.0f}, {325.0f,-470.0f}, {361.0f,-470.0f}, {394.33f,-479.0f}, {425.0f,-497.0f},
    {455.67f,-515.0f}, {480.0f,-539.33f}, {498.0f,-570.0f}, {516.0f,-600.67f}, {525.0f,-634.0f},
    {525.0f,-670.0f}, {525.0f,-706.0f}, {516.0f,-739.33f}, {498.0f,-770.0f}, {480.0f,-800.67f},
    {455.67f,-825.0f}, {425.0f,-843.0f}, {394.33f,-861.0f}, {361.0f,-870.0f}, {325.0f,-870.0f},
    {289.0f,-870.0f}, {255.67f,-861.0f}, {225.0f,-843.0f}, {194.33f,-825.0f}, {170.0f,-800.67f},
    {152.0f,-770.0f}, {134.0f,-739.33f}, {125.0f,-706.0f}, {125.0f,-670.0f}, {450.0f,-195.0f},
    {450.0f,-217.67f}, {444.33f,-238.5f}, {433.0f,-257.5f}, {421.67f,-276.5f},
    {406.5f,-291.67f}, {387.5f,-303.0f}, {368.5f,-314.33f}, {347.67f,-320.0f}, {325.0f,-320.0f},
    {302.33f,-320.0f}, {281.5f,-314.33f}, {262.5f,-303.0f}, {243.5f,-291.67f},
    {228.33f,-276.5f}, {217.0f,-257.5f}, {205.67f,-238.5f}, {200.0f,-217.67f}, {200.0f,-195.0f},
    {200.0f,-70.0f}, {450.0f,-70.0f}, {550.0f,30.0f}, {100.0f,30.0f}, {100.0f,-195.0f},
    {100.0f,-235.67f}, {110.17f,-273.17f}, {130.5f,-307.5f}, {150.83f,-341.83f},
    {178.17f,-369.17f}, {212.5f,-389.5f}, {246.83f,-409.83f}, {284.33f,-420.0f},
    {325.0f,-420.0f}, {365.67f,-420.0f}, {403.17f,-409.83f}, {437.5f,-389.5f},
    {471.83f,-369.17f}, {499.17f,-341.83f}, {519.5f,-307.5f}, {539.83f,-273.17f},
    {550.0f,-235.67f}, {550.0f,-195.0f}, {975.0f,-670.0f}, {975.0f,-652.0f}, {970.5f,-635.33f},
    {961.5f,-620.0f}, {952.5f,-604.67f}, {940.33f,-592.5f}, {925.0f,-583.5f}, {909.67f,-574.5f},
    {893.0f,-570.0f}, {875.0f,-570.0f}, {857.0f,-570.0f}, {840.33f,-574.5f}, {825.0f,-583.5f},
    {809.67f,-592.5f}, {797.5f,-604.67f}, {788.5f,-620.0f}, {779.5f,-635.33f}, {775.0f,-652.0f},
    {775.0f,-670.0f}, {775.0f,-688.0f}, {779.5f,-704.67f}, {788.5f,-720.0f}, {797.5f,-735.33f},
    {809.67f,-747.5f}, {825.0f,-756.5f}, {840.33f,-765.5f}, {857.0f,-770.0f}, {875.0f,-770.0f},
    {893.0f,-770.0f}, {909.67f,-765.5f}, {925.0f,-756.5f}, {940.33f,-747.5f}, {952.5f,-735.33f},
    {961.5f,-720.0f}, {970.5f,-704.67f}, {975.0f,-688.0f}, {975.0f,-670.0f}, {675.0f,-670.0f},
    {675.0f,-634.0f}, {684.0f,-600.67f}, {702.0f,-570.0f}, {720.0f,-539.33f}, {744.33f,-515.0f},
    {775.0f,-497.0f}, {805.67f,-479.0f}, {839.0f,-470.0f}, {875.0f,-470.0f}, {911.0f,-470.0f},
    {944.33f,-479.0f}, {975.0f,-497.0f}, {1005.67f,-515.0f}, {1030.0f,-539.33f},
    {1048.0f,-570.0f}, {1066.0f,-600.67f}, {1075.0f,-634.0f}, {1075.0f,-670.0f},
    {1075.0f,-706.0f}, {1066.0f,-739.33f}, {1048.0f,-770.0f}, {1030.0f,-800.67f},
    {1005.67f,-825.0f}, {975.0f,-843.0f}, {944.33f,-861.0f}, {911.0f,-870.0f}, {875.0f,-870.0f},
    {839.0f,-870.0f}, {805.67f,-861.0f}, {775.0f,-843.0f}, {744.33f,-825.0f}, {720.0f,-800.67f},
    {702.0f,-770.0f}, {684.0f,-739.33f}, {675.0f,-706.0f}, {675.0f,-670.0f}, {1000.0f,-195.0f},
    {1000.0f,-217.67f}, {994.33f,-238.5f}, {983.0f,-257.5f}, {971.67f,-276.5f},
    {956.5f,-291.67f}, {937.5f,-303.0f}, {918.5f,-314.33f}, {897.67f,-320.0f}, {875.0f,-320.0f},
    {852.33f,-320.0f}, {831.5f,-314.33f}, {812.5f,-303.0f}, {793.5f,-291.67f},
    {778.33f,-276.5f}, {767.0f,-257.5f}, {755.67f,-238.5f}, {750.0f,-217.67f}, {750.0f,-195.0f},
    {750.0f,-70.0f}, {1000.0f,-70.0f}, {650.0f,-70.0f}, {650.0f,-195.0f}, {650.0f,-235.67f},
    {660.17f,-273.17f}, {680.5f,-307.5f}, {700.83f,-341.83f}, {728.17f,-369.17f},
    {762.5f,-389.5f}, {796.83f,-409.83f}, {834.33f,-420.0f}, {875.0f,-420.0f},
    {915.67f,-420.0f}, {953.17f,-409.83f}, {987.5f,-389.5f}, {1021.83f,-369.17f},
    {1049.17f,-341.83f}, {1069.5f,-307.5f}, {1089.83f,-273.17f}, {1100.0f,-235.67f},
    {1100.0f,-195.0f}, {1100.0f,30.0f}, {650.0f,30.0f},
};
static const BYTE kRemixGroupTypes[] = {
    0x00, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
    0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
    0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x83, 0x00, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
    0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
    0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x83, 0x00,
    0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
    0x03, 0x03, 0x03, 0x01, 0x81, 0x00, 0x01, 0x01, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
    0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x83, 0x00, 0x03, 0x03, 0x03,
    0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
    0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
    0x03, 0x03, 0x83, 0x00, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
    0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
    0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x83, 0x00, 0x03, 0x03, 0x03, 0x03,
    0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x01,
    0x81, 0x00, 0x01, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
    0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x01, 0x81,
};
static const RemixGlyphDef kRemixGroup{
    kRemixGroupPts, kRemixGroupTypes, 233};
// ops: {'moveTo': 8, 'qCurveTo': 8, 'closePath': 8, 'lineTo': 9}
// U+F080 restart_line (restart-line): 1 contours, 84 points, ink bbox x[100..1100] y[-920..80]
static const GlyphPt kRemixRefreshPts[] = {
    {927.0f,-42.0f}, {882.33f,-3.33f}, {832.33f,26.67f}, {777.0f,48.0f}, {720.33f,69.33f},
    {661.33f,80.0f}, {600.0f,80.0f}, {532.0f,80.0f}, {467.0f,67.0f}, {405.0f,41.0f},
    {345.67f,15.67f}, {292.83f,-20.17f}, {246.5f,-66.5f}, {200.17f,-112.83f},
    {164.33f,-165.67f}, {139.0f,-225.0f}, {113.0f,-287.0f}, {100.0f,-352.0f}, {100.0f,-420.0f},
    {100.0f,-488.0f}, {113.0f,-553.0f}, {139.0f,-615.0f}, {164.33f,-674.33f},
    {200.17f,-727.17f}, {246.5f,-773.5f}, {292.83f,-819.83f}, {345.67f,-855.67f},
    {405.0f,-881.0f}, {467.0f,-907.0f}, {532.0f,-920.0f}, {600.0f,-920.0f}, {668.0f,-920.0f},
    {733.0f,-907.0f}, {795.0f,-881.0f}, {854.33f,-855.67f}, {907.17f,-819.83f},
    {953.5f,-773.5f}, {999.83f,-727.17f}, {1035.67f,-674.33f}, {1061.0f,-615.0f},
    {1087.0f,-553.0f}, {1100.0f,-488.0f}, {1100.0f,-420.0f}, {1100.0f,-367.33f},
    {1092.0f,-316.33f}, {1076.0f,-267.0f}, {1060.67f,-219.0f}, {1038.33f,-174.33f},
    {1009.0f,-133.0f}, {850.0f,-420.0f}, {1000.0f,-420.0f}, {1000.0f,-492.67f},
    {981.67f,-560.0f}, {945.0f,-622.0f}, {909.67f,-682.0f}, {862.0f,-729.67f}, {802.0f,-765.0f},
    {740.0f,-801.67f}, {672.67f,-820.0f}, {600.0f,-820.0f}, {527.33f,-820.0f},
    {460.0f,-801.67f}, {398.0f,-765.0f}, {338.0f,-729.67f}, {290.33f,-682.0f}, {255.0f,-622.0f},
    {218.33f,-560.0f}, {200.0f,-492.67f}, {200.0f,-420.0f}, {200.0f,-347.33f},
    {218.33f,-280.0f}, {255.0f,-218.0f}, {290.33f,-158.0f}, {338.0f,-110.33f}, {398.0f,-75.0f},
    {460.0f,-38.33f}, {527.33f,-20.0f}, {600.0f,-20.0f}, {652.67f,-20.0f}, {703.33f,-30.0f},
    {752.0f,-50.0f}, {798.67f,-69.33f}, {840.33f,-96.33f}, {877.0f,-131.0f},
};
static const BYTE kRemixRefreshTypes[] = {
    0x00, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
    0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
    0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
    0x03, 0x03, 0x03, 0x03, 0x01, 0x01, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
    0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
    0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x83,
};
static const RemixGlyphDef kRemixRefresh{
    kRemixRefreshPts, kRemixRefreshTypes, 84};
// ops: {'moveTo': 1, 'qCurveTo': 20, 'lineTo': 2, 'closePath': 1}
// ---- end glyph data ----

// ---- 接续箭头(↓ 接回本机 / ↑ 推到该设备) ----
// 手写轮廓(粗竖杆 + 三角头),**放在生成区标记之外**——上面的数据区由
// tool/gen_lyric_glyphs.py --patch 整体重写,手写数据混在里面会被清掉
// (2026-09-10 实际发生:补三个设备行图标时箭头轮廓被 patch 抹掉,编译失败)。
// 坐标空间与生成数据一致:upm=1200、Y 向下为正;实际字号由 kHandoffEm 控制。
// ↓ = 竖杆(460..740, 80..560) + 三角头(220..980, 尖点 600,1080)。
static const GlyphPt kArrowDownPts[] = {
    {460.0f, 80.0f}, {740.0f, 80.0f}, {740.0f, 560.0f}, {460.0f, 560.0f},
    {220.0f, 520.0f}, {980.0f, 520.0f}, {600.0f, 1080.0f},
};
static const BYTE kArrowDownTypes[] = {
    0x00, 0x01, 0x01, 0x81,  // 竖杆矩形(4 点)
    0x00, 0x01, 0x81,        // 三角头(3 点)
};
static const RemixGlyphDef kArrowDown{
    kArrowDownPts, kArrowDownTypes, 7};
// ↑ = 上下镜像:竖杆(460..740, 640..1120) + 三角头(尖点 600,120)。
static const GlyphPt kArrowUpPts[] = {
    {460.0f, 640.0f}, {740.0f, 640.0f}, {740.0f, 1120.0f}, {460.0f, 1120.0f},
    {220.0f, 680.0f}, {980.0f, 680.0f}, {600.0f, 120.0f},
};
static const BYTE kArrowUpTypes[] = {
    0x00, 0x01, 0x01, 0x81,  // 竖杆矩形(4 点)
    0x00, 0x01, 0x81,        // 三角头(3 点)
};
static const RemixGlyphDef kArrowUp{
    kArrowUpPts, kArrowUpTypes, 7};

// 把 remix 轮廓按 [em] 字号等比缩放,ink 外接框居中于 (cx, cy) 后填充。
// 轮廓数据内嵌在二进制里,不存在「字体加载失败」(历史上运行时加载字体在
// 本机全堵死:AddFontResourceExW 对 GDI+ 不可见、PrivateFontCollection 在
// gdiplus 10.0.x 拿不到 status 14),所以没有也不需要降级分支。
void DrawRemixGlyphAt(gd::Graphics& g, const RemixGlyphDef& def, REAL cx,
                      REAL cy, REAL em, const gd::Color& color) {
  const REAL scale = em / 1200.0f;
  REAL minX = FLT_MAX, minY = FLT_MAX, maxX = -FLT_MAX, maxY = -FLT_MAX;
  for (int i = 0; i < def.count; ++i) {
    minX = std::min(minX, def.pts[i].x);
    maxX = std::max(maxX, def.pts[i].x);
    minY = std::min(minY, def.pts[i].y);
    maxY = std::max(maxY, def.pts[i].y);
  }
  const REAL ox = cx - (minX + maxX) * 0.5f * scale;
  const REAL oy = cy - (minY + maxY) * 0.5f * scale;
  std::vector<gd::PointF> pts(def.count);
  for (int i = 0; i < def.count; ++i) {
    pts[i] = gd::PointF(def.pts[i].x * scale + ox, def.pts[i].y * scale + oy);
  }
  gd::GraphicsPath path(pts.data(), def.types, def.count);
  if (path.GetLastStatus() != gd::Ok) return;
  gd::SolidBrush br(color);
  g.FillPath(&br, &path);
}

// 按 remix 字号 Sf(19)(ink 尺寸与相邻 Segoe em20 字形相近)居中画在按钮上。
void DrawRemixGlyph(gd::Graphics& g, const RemixGlyphDef& def,
                    const BtnGeom& b, const gd::Color& color) {
  DrawRemixGlyphAt(g, def, static_cast<REAL>(b.cx), static_cast<REAL>(b.cy),
                   Sf(19), color);
}

void DrawButton(gd::Graphics& g, int idx) {
  const BtnGeom b = ButtonGeom(idx);
  const bool hot = g_hovering && g_hotButton == idx;
  // 悬停高亮圆形底。
  if (hot) {
    const int pad = S(4);
    gd::SolidBrush br(Gd(idx == kBtnIdxLike ? kLikeHoverBg : kHoverBg));
    g.FillEllipse(&br, static_cast<REAL>(b.cx - b.r - pad),
                  static_cast<REAL>(b.cy - b.r - pad),
                  static_cast<REAL>((b.r + pad) * 2),
                  static_cast<REAL>((b.r + pad) * 2));
  }
  // 按钮圆底。
  gd::SolidBrush br(Gd(idx == kBtnIdxPlay ? kPlayBtnBg : kBtnBg));
  g.FillEllipse(&br, static_cast<REAL>(b.cx - b.r),
                static_cast<REAL>(b.cy - b.r), static_cast<REAL>(b.r * 2),
                static_cast<REAL>(b.r * 2));
  // 图标(Segoe MDL2 Assets 字形;队列/顺序播放为硬编码 remix 轮廓)。
  const gd::Color iconColor =
      Gd(hot ? RGB(255, 255, 255)
             : (idx == kBtnIdxLike && g_liked ? kLikeColor : kIconColor));
  wchar_t glyph = 0;
  const gd::Font* font = g_fontIcon;
  switch (idx) {
    case kBtnIdxPrev: glyph = kGlyphPrev; break;
    case kBtnIdxPlay:
      glyph = g_playing ? kGlyphPause : kGlyphPlay;
      font = g_fontIconPlay;
      break;
    case kBtnIdxNext: glyph = kGlyphNext; break;
    case kBtnIdxMode:
      // 顺序播放(order):与 MINI 播放器同款 remix 有序列表图形
      // (硬编码轮廓);其余模式用 Segoe 字形。
      if (g_mode == kModeOrder) {
        DrawRemixGlyph(g, kRemixOrder, b, iconColor);
        return;
      }
      glyph = g_mode == kModeShuffle
                  ? kGlyphShuffle
                  : (g_mode == kModeRepeatOne ? kGlyphRepeatOne
                                              : kGlyphRepeatAll);
      break;
    case kBtnIdxVolume: glyph = kGlyphVolume; break;
    case kBtnIdxLike:
      glyph = g_liked ? kGlyphHeartFill : kGlyphHeart;
      break;
    case kBtnIdxQueue:
      // 播放队列:MINI 播放器同款 remix 图标(硬编码轮廓)。
      DrawRemixGlyph(g, kRemixQueue, b, iconColor);
      return;
    case kBtnIdxSwitch:
      // 切换播放器:与主界面同款 remix「设备切换」图形(硬编码轮廓),
      // 点击后通知 Flutter 打开「选择播放器」弹窗。
      DrawRemixGlyph(g, kRemixSwitchPlayer, b, iconColor);
      return;
  }
  DrawGlyphGd(g, b, glyph, font, iconColor);
}

void DrawVolumePopup(gd::Graphics& g) {
  if (g_popup != PopupKind::Volume) return;
  const RECT panel = VolumePanelRect();
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

// 列表弹窗(队列/设备)共用外框:面板底 + 描边 + 与歌词区之间的桥接带。
void DrawListPanelChrome(gd::Graphics& g, const RECT& panel) {
  const REAL px = static_cast<REAL>(panel.left);
  const REAL py = static_cast<REAL>(panel.top);
  const REAL pw = static_cast<REAL>(panel.right - panel.left);
  const REAL ph = static_cast<REAL>(panel.bottom - panel.top);
  const int rad = S(10);
  FillRoundRect(g, px, py, pw, ph, static_cast<REAL>(rad),
                Gd(kPanelBg, kPopupPanelAlpha));
  {
    gd::GraphicsPath* p = RoundRectPath(px, py, pw, ph, static_cast<REAL>(rad));
    gd::Pen pen(Gd(kPanelBorder), 1.0f);
    g.DrawPath(&pen, p);
    delete p;
  }
  gd::SolidBrush br(Gd(kPanelBg, kPopupPanelAlpha));
  g.FillRectangle(&br, px + 1, py + ph, pw - 2,
                  static_cast<REAL>(g_popupH - panel.bottom));
}

// 队列弹窗:序号 + 歌名 — 歌手(单行省略),当前曲 accent 高亮 + 行底色。
void DrawQueuePopup(gd::Graphics& g) {
  if (g_popup != PopupKind::Queue || g_queueItems.empty()) return;
  const RECT panel = ListPanelRect();
  DrawListPanelChrome(g, panel);
  const RECT rows = ListRowsRect();
  const int slot = ListRowH() + ListRowGap();
  const COLORREF kNumColor = RGB(150, 154, 163);
  gd::StringFormat sf;
  sf.SetTrimming(gd::StringTrimmingEllipsisCharacter);
  sf.SetFormatFlags(gd::StringFormatFlagsNoWrap |
                    gd::StringFormatFlagsMeasureTrailingSpaces);
  sf.SetLineAlignment(gd::StringAlignmentCenter);
  g.SetClip(gd::RectF(static_cast<REAL>(rows.left),
                      static_cast<REAL>(panel.top),
                      static_cast<REAL>(rows.right - rows.left),
                      static_cast<REAL>(rows.bottom - rows.top)),
            gd::CombineModeReplace);
  for (int i = g_queueScroll;
       i < static_cast<int>(g_queueItems.size()); ++i) {
    const int rowTop = rows.top + (i - g_queueScroll) * slot;
    if (rowTop + ListRowH() > rows.bottom) break;
    const bool current = i == g_queueIndex;
    const bool hot = g_hovering && g_hotRow == i && !current;
    if (current || hot) {
      FillRoundRect(g, static_cast<REAL>(rows.left),
                    static_cast<REAL>(rowTop),
                    static_cast<REAL>(rows.right - rows.left),
                    static_cast<REAL>(ListRowH()), static_cast<REAL>(S(6)),
                    Gd(current ? kHoverBg : kBtnBg));
    }
    const COLORREF mainColor = current ? g_lyricColor : kTextColor;
    const COLORREF dimColor = current ? g_lyricColor : kNumColor;
    wchar_t num[8];
    swprintf(num, 8, L"%02d", i + 1);
    if (g_fontPopup) {
      gd::SolidBrush nb(Gd(dimColor));
      gd::RectF numRf(static_cast<REAL>(rows.left + S(6)),
                      static_cast<REAL>(rowTop), static_cast<REAL>(S(36)),
                      static_cast<REAL>(ListRowH()));
      // 长度必须按实际字符数(-1=null 结尾):写死 2 会把 3 位以上序号截断。
      g.DrawString(num, -1, g_fontPopup, numRf, &sf, &nb);
      gd::SolidBrush tb(Gd(mainColor));
      gd::RectF titleRf(
          static_cast<REAL>(rows.left + S(48)), static_cast<REAL>(rowTop),
          static_cast<REAL>(rows.right - rows.left - S(54)),
          static_cast<REAL>(ListRowH()));
      const std::wstring& text = g_queueItems[i];
      g.DrawString(text.c_str(), static_cast<INT>(text.size()), g_fontPopup,
                   titleRf, &sf, &tb);
    }
  }
  g.ResetClip();
}

// 「切换播放器」弹窗:每行两行文字(设备名 / 状态副标题),当前控制目标高亮。
// 内容与 MINI 播放条的小弹窗一致,由 Flutter 组好文本推送(见
// DesktopLyricUpdateSwitch),原生层只负责画与回传行号。
void DrawSwitchPopup(gd::Graphics& g) {
  if (g_popup != PopupKind::Switch) return;
  const RECT panel = SwitchPanelRect();
  DrawListPanelChrome(g, panel);
  const RECT rows = ListRowsRect();
  const int slot = ListRowH() + ListRowGap();
  gd::StringFormat sf;
  sf.SetTrimming(gd::StringTrimmingEllipsisCharacter);
  sf.SetFormatFlags(gd::StringFormatFlagsNoWrap |
                    gd::StringFormatFlagsMeasureTrailingSpaces);
  sf.SetLineAlignment(gd::StringAlignmentCenter);
  g.SetClip(gd::RectF(static_cast<REAL>(rows.left),
                      static_cast<REAL>(panel.top),
                      static_cast<REAL>(rows.right - rows.left),
                      static_cast<REAL>(rows.bottom - rows.top)),
            gd::CombineModeReplace);

  // 无设备时(加载中 / 确实没有可用设备)画一行提示,避免空面板。
  if (g_switchItems.empty()) {
    if (g_fontPopup) {
      const wchar_t* hint =
          g_switchLoading ? L"正在加载播放器…" : L"没有可用的播放器";
      gd::SolidBrush hb(Gd(RGB(150, 154, 163)));
      gd::RectF rf(static_cast<REAL>(rows.left), static_cast<REAL>(rows.top),
                   static_cast<REAL>(rows.right - rows.left),
                   static_cast<REAL>(ListRowH()));
      g.DrawString(hint, -1, g_fontPopup, rf, &sf, &hb);
    }
    g.ResetClip();
    return;
  }

  const COLORREF kSubColor = RGB(150, 154, 163);
  for (int i = g_switchScroll; i < static_cast<int>(g_switchItems.size());
       ++i) {
    const int rowTop = rows.top + (i - g_switchScroll) * slot;
    if (rowTop + ListRowH() > rows.bottom) break;
    const LyricSwitchItem& item = g_switchItems[i];
    const bool arrowHot =
        g_hovering && g_hotSwitchAction >= 0 && g_hotSwitchRow == i;
    const bool hot =
        g_hovering && g_hotRow == i && !item.current && !arrowHot;
    if (item.current || hot) {
      FillRoundRect(g, static_cast<REAL>(rows.left), static_cast<REAL>(rowTop),
                    static_cast<REAL>(rows.right - rows.left),
                    static_cast<REAL>(ListRowH()), static_cast<REAL>(S(6)),
                    Gd(item.current ? kHoverBg : kBtnBg));
    }
    if (g_fontPopup) {
      // 「刷新设备列表」行是操作行,标题用弱色(与 MINI 弹窗操作行观感一致)。
      const COLORREF titleColor = item.isRefresh
          ? kSubColor
          : (item.current ? g_lyricColor : kTextColor);
      // 行首图标:与 MINI 弹窗同款(1=耳机 2=基站 3=人群 4=刷新),
      // 用离线提取的 remixicon 轮廓画;icon=0 时退回小圆点兜底。
      // 当前项用歌词色点亮(与 MINI 的选中色一致)。
      const int dotCx = rows.left + S(13);
      const int dotCy = rowTop + ListRowH() / 2;
      const RemixGlyphDef* rowGlyph = nullptr;
      switch (item.icon) {
        case 1: rowGlyph = &kRemixHeadphone; break;
        case 2: rowGlyph = &kRemixSwitchPlayer; break;
        case 3: rowGlyph = &kRemixGroup; break;
        case 4: rowGlyph = &kRemixRefresh; break;
        default: break;
      }
      if (rowGlyph != nullptr) {
        DrawRemixGlyph(g, *rowGlyph,
                       BtnGeom{dotCx, dotCy, S(9)},
                       Gd(item.current ? g_lyricColor : kIconColor));
      } else if (!item.isRefresh) {
        const int dotR = S(3);
        gd::SolidBrush db(Gd(item.current ? g_lyricColor : kIconColor));
        g.FillEllipse(&db, static_cast<REAL>(dotCx - dotR),
                      static_cast<REAL>(dotCy - dotR),
                      static_cast<REAL>(dotR * 2), static_cast<REAL>(dotR * 2));
      }
      const REAL textLeft = static_cast<REAL>(rows.left + S(26));
      // 文本区要给行右侧的接续箭头让位(没有箭头的行则占满整行)。
      const REAL textW = static_cast<REAL>(rows.right - rows.left - S(26) -
                                           HandoffAreaW(item));
      const int halfH = ListRowH() / 2;
      gd::SolidBrush tb(Gd(titleColor));
      // 刷新行单行文本垂直居中;设备行是两行布局,标题在上半部。
      gd::RectF titleRf(
          textLeft,
          static_cast<REAL>(rowTop + (item.isRefresh ? 0 : S(4))), textW,
          static_cast<REAL>(item.isRefresh ? ListRowH() : halfH));
      g.DrawString(item.title.c_str(), static_cast<INT>(item.title.size()),
                   g_fontPopup, titleRf, &sf, &tb);
      // 设备类型小徽章(DLNA/群组…):紧跟设备名,与 MINI 弹窗 _DlnaBadge
      // 同位置。先量出标题实际宽度再原位画;宽度不够就干脆不画(宁缺勿压字)。
      if (!item.badge.empty() && g_fontBadge) {
        gd::RectF titleBox;
        g.MeasureString(item.title.c_str(),
                        static_cast<INT>(item.title.size()), g_fontPopup,
                        gd::PointF(0.0f, 0.0f), &titleBox);
        gd::RectF badgeBox;
        g.MeasureString(item.badge.c_str(),
                        static_cast<INT>(item.badge.size()), g_fontBadge,
                        gd::PointF(0.0f, 0.0f), &badgeBox);
        const REAL bw = badgeBox.Width + 2 * S(kBadgePadX);
        const REAL bh = badgeBox.Height + 2 * S(kBadgePadY);
        const REAL bx =
            textLeft + std::min(titleBox.Width, textW) + S(kBadgeGap);
        if (bx + bw <= textLeft + textW) {
          const REAL by = titleRf.Y + (static_cast<REAL>(halfH) - bh) * 0.5f;
          FillRoundRect(g, bx, by, bw, bh, static_cast<REAL>(S(3)),
                        Gd(kTrackColor, 210));
          {
            gd::GraphicsPath* p =
                RoundRectPath(bx, by, bw, bh, static_cast<REAL>(S(3)));
            gd::Pen pen(Gd(kPanelBorder, 210), 1.0f);
            g.DrawPath(&pen, p);
            delete p;
          }
          gd::SolidBrush bb(Gd(kSubColor));
          gd::RectF btRf(bx + S(kBadgePadX), by + S(kBadgePadY),
                         badgeBox.Width + S(1), badgeBox.Height + S(1));
          g.DrawString(item.badge.c_str(),
                       static_cast<INT>(item.badge.size()), g_fontBadge, btRf,
                       &sf, &bb);
        }
      }
      if (!item.subtitle.empty()) {
        gd::SolidBrush sb(Gd(item.current ? g_lyricColor : kSubColor));
        gd::RectF subRf(textLeft, static_cast<REAL>(rowTop + halfH),
                        textW, static_cast<REAL>(halfH - S(4)));
        g.DrawString(item.subtitle.c_str(),
                     static_cast<INT>(item.subtitle.size()), g_fontPopup,
                     subRf, &sf, &sb);
      }
    }
    // 行右侧的接续箭头(↓ 接回本机 / ↑ 推到该设备):与 MINI 弹窗
    // PeerCastRow 的 _HandoffButton 同序同义 —— 先 ↓ 后 ↑,无「现场」
    // 可搬时置灰。
    //
    // **显示条件是 handoff 而不是 canPull||canPush**:MINI 弹窗的设备行
    // 永远有两支箭头,两支都不可用时也只是变灰。用 or 兼作显示条件会让
    // 整块箭头在「没有现场可搬」时凭空消失,用户看到的就是「歌词窗比
    // MINI 少了功能」(2026-09-10 实测反馈)。
    if (item.handoff) {
      const int r = HandoffRadius();
      const int cy = HandoffCy(rowTop);
      for (int which = 1; which >= 0; --which) {
        const bool enabled = which == 0 ? item.canPull : item.canPush;
        const int cx = HandoffCx(rows, which);
        const bool hotBtn = g_hovering && g_hotSwitchAction == which &&
                            g_hotSwitchRow == i;
        if (hotBtn) {
          const int pad = S(2);
          gd::SolidBrush br(Gd(kHoverBg, 235));
          g.FillEllipse(&br, static_cast<REAL>(cx - r - pad),
                        static_cast<REAL>(cy - r - pad),
                        static_cast<REAL>((r + pad) * 2),
                        static_cast<REAL>((r + pad) * 2));
        }
        DrawRemixGlyphAt(g, which == 0 ? kArrowDown : kArrowUp,
                         static_cast<REAL>(cx), static_cast<REAL>(cy),
                         Sf(kHandoffEm), Gd(enabled ? g_lyricColor : kOffColor));
      }
    }
  }
  g.ResetClip();
}
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

// 独立测量文本宽(物理 px):AddString + GetBounds 不依赖 DC。
double MeasureTextWidth(const std::wstring& text, const gd::FontFamily* family,
                        gd::FontStyle style, REAL sizePx) {
  if (text.empty() || family == nullptr) return 0;
  gd::GraphicsPath path;
  path.AddString(text.c_str(), static_cast<INT>(text.size()), family, style,
                 sizePx, gd::PointF(0, 0),
                 gd::StringFormat::GenericTypographic());
  gd::RectF bounds{};
  if (path.GetBounds(&bounds) != gd::Ok) return 0;
  return bounds.Width;
}

// 跑马灯当前偏移(A 方案):起点停 hold → 匀速滚到尾 → 终点停 hold → 循环。
REAL CurrentScrollOffset(REAL overflow) {
  if (overflow <= 2) return 0;
  if (g_scrollCycle == 0) g_scrollCycle = GetTickCount64();
  const double speed = S(kScrollSpeed);  // 物理 px/s
  const ULONGLONG scrollMs =
      static_cast<ULONGLONG>(overflow / speed * 1000.0);
  const ULONGLONG total = kScrollHoldMs + scrollMs + kScrollHoldMs;
  const ULONGLONG p = (GetTickCount64() - g_scrollCycle) % total;
  if (p < kScrollHoldMs) return 0;
  if (p < kScrollHoldMs + scrollMs) {
    return static_cast<REAL>(overflow *
                             static_cast<double>(p - kScrollHoldMs) /
                             static_cast<double>(scrollMs));
  }
  return overflow;
}

// 超宽时开定时器驱动滚动重绘,不需要时关掉。
void UpdateScrollTimer(bool need) {
  if (!g_hwnd) return;
  if (need && !g_scrollTimerOn) {
    SetTimer(g_hwnd, kScrollTimerId, kScrollTimerMs, nullptr);
    g_scrollTimerOn = true;
  } else if (!need && g_scrollTimerOn) {
    KillTimer(g_hwnd, kScrollTimerId);
    g_scrollTimerOn = false;
  }
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
  // 歌词行:超宽时跑马灯左滚,水平裁剪在可用宽度内(左右各留 padX)。
  const REAL lyricSize = Sf(kLyricFontSize);
  // 右侧为悬停按钮栏预留空间(按钮自右缘向左排到 kOffPrev),
  // 否则超长歌词跑马灯会从按钮底下穿过。
  const REAL btnZoneW = static_cast<REAL>(
      S(kOffPrev) + (g_hovering ? S(kBtnR) + S(6) : 0));
  const REAL availW =
      w - 2 * static_cast<REAL>(g_padX) - (g_hovering ? btnZoneW : 0.0f);
  const double textW =
      MeasureTextWidth(lyric, g_famUI, gd::FontStyleBold, lyricSize);
  g_lyricOverflow = textW > 0 ? (textW - availW) : 0.0;
  UpdateScrollTimer(g_lyricOverflow > 2);
  const REAL scrollX = CurrentScrollOffset(
      static_cast<REAL>(g_lyricOverflow));
  g.SetClip(gd::RectF(static_cast<REAL>(g_padX), baseY, availW, hLyric),
            gd::CombineModeReplace);
  DrawOutlinedText(g, lyric, g_famUI, gd::FontStyleBold, lyricSize,
                   static_cast<REAL>(g_padX) - scrollX,
                   baseY + hLyric * 0.66f, Gd(g_lyricColor),
                   Gd(ComputeLyricStrokeColor(g_lyricColor)),
                   Sf(kLyricStrokeW) * 0.5f);
  g.ResetClip();

  // 悬停时:按钮;弹窗展开时:对应面板。
  if (g_hovering) {
    for (int i = 0; i < kBtnCount; ++i) DrawButton(g, i);
  }
  DrawVolumePopup(g);
  DrawQueuePopup(g);
  DrawSwitchPopup(g);

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

// 弹窗区高度变化后同步窗口几何:窗口顶随之升降,保证歌词区位置不动。
void SyncWindowHeight(int oldH) {
  if (!g_hwnd || g_popupH == oldH) return;
  RECT rc{};
  GetWindowRect(g_hwnd, &rc);
  SetWindowPos(g_hwnd, nullptr, rc.left, rc.top + (oldH - g_popupH),
               g_curWidth, TotalHeight(), SWP_NOZORDER | SWP_NOACTIVATE);
}

void SetPopup(PopupKind kind) {
  if (g_popup == kind) return;
  const int oldH = g_popupH;
  const PopupKind prev = g_popup;
  g_popup = kind;
  if (kind != PopupKind::Queue) g_queueScroll = 0;
  if (kind != PopupKind::Switch) g_switchScroll = 0;
  if (kind != PopupKind::Volume) g_sliderDragging = false;
  g_hotRow = -1;
  g_hotSwitchAction = -1;
  g_hotSwitchRow = -1;
  g_popupH = S(PopupLogicalHeight(kind));
  SyncWindowHeight(oldH);
  RepaintLyric();
  // 切换弹窗收起时通知 Dart:设备行「正在播放」的实时刷新循环靠它停表
  // (弹窗在时 Dart 每 5s 重组重推;收起后继续推就是无谓跨端调用)。
  if (prev == PopupKind::Switch && kind == PopupKind::None) {
    FireEvent("switch_close");
  }
}

// 按光标客户区坐标刷新按钮/列表行高亮(MOUSEMOVE 与轮询共用)。
void UpdateHotFromPoint(const POINT& pt) {
  const int hot = HitTestButton(pt);
  const bool inPanel = PtInPanel(pt);
  int newHot = hot;
  if (newHot < 0 && inPanel) {
    // 弹窗内视作所属按钮高亮(音量→音量按钮,其余→各自展开按钮)。
    newHot = g_popup == PopupKind::Volume
                 ? kBtnIdxVolume
                 : (g_popup == PopupKind::Switch ? kBtnIdxSwitch
                                                 : kBtnIdxQueue);
  }
  int newHotRow = -1;
  if (inPanel && g_popup != PopupKind::Volume) {
    newHotRow = HitTestListRow(pt);
  }
  // 设备行内的接续箭头(↓/↑)优先级高于整行:压在箭头上时整行不再高亮,
  // 免得看不出点的是「搬现场」还是「切控制目标」。
  int newHotAction = -1;
  int newHotActionRow = -1;
  if (inPanel && g_popup == PopupKind::Switch) {
    int actionRow = -1;
    const int action = HitTestSwitchHandoff(pt, &actionRow);
    if (action >= 0) {
      newHotAction = action;
      newHotActionRow = actionRow;
    }
  }
  if (newHot != g_hotButton || newHotRow != g_hotRow ||
      newHotAction != g_hotSwitchAction ||
      newHotActionRow != g_hotSwitchRow) {
    g_hotButton = newHot;
    g_hotRow = newHotRow;
    g_hotSwitchAction = newHotAction;
    g_hotSwitchRow = newHotActionRow;
    RepaintLyric();
  }
}

// 悬停状态轮询(30ms 一拍,仅可见时运行):光标落在歌词区矩形内(弹窗展开时
// 含弹窗条带,见 HoverTopLimit)即视为悬停——不按像素 alpha 命中,歌词笔画
// 间隙/按钮边缘高亮稳定;移出后一拍内清高亮并收起弹窗(拖窗/拖滑条期间
// 跳过,由 capture 接管)。弹窗未展开时上方弹窗区不计入悬停:alpha=0 本就
// 不接收系统鼠标,若按整窗矩形判定,鼠标掠过歌词上方空白区就会误点亮
// 整条悬停高亮(2026-09-09 用户反馈,音量弹窗收起后残留可交互区域)。
void UpdateHoverState() {
  if (!g_hwnd || !g_visible || g_dragging) return;
  POINT pt{};
  bool inside = false;
  if (GetCursorPos(&pt) && ScreenToClient(g_hwnd, &pt)) {
    inside = pt.x >= 0 && pt.x < g_curWidth && pt.y >= HoverTopLimit() &&
             pt.y < TotalHeight();
  }
  if (!inside) {
    if (g_sliderDragging) return;
    if (g_hovering) {
      g_hovering = false;
      g_hotButton = -1;
      g_hotRow = -1;
      g_hotSwitchAction = -1;
      g_hotSwitchRow = -1;
      g_sliderDragging = false;
      SetPopup(PopupKind::None);
      RepaintLyric();
    }
    return;
  }
  if (!g_hovering) {
    g_hovering = true;
    RepaintLyric();
  }
  UpdateHotFromPoint(pt);
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
      if (g_pressPending) {
        // 按下后移动超过阈值 → 判定为拖动窗口;否则保持待判定(单击)。
        // 阈值公式在 dllogic::MovedBeyondThreshold(带独立单测)。
        const int dx = pt.x - g_pressPt.x;
        const int dy = pt.y - g_pressPt.y;
        if (dllogic::MovedBeyondThreshold(dx, dy, S(6))) {
          g_pressPending = false;
          g_dragging = true;
          g_dragOffset = g_pressPt;
        } else {
          return 0;
        }
      }
      if (g_sliderDragging) {
        SetVolumeAndNotify(VolumeFromY(pt.y));
        return 0;
      }
      // 悬停进出由轮询定时器统一判定;这里仅做即时高亮响应(不等下一拍)。
      // 与轮询同规则(弹窗未展开时弹窗条带不计入):过滤弹窗刚收起后队列中
      // 残留的 MOUSEMOVE,防止高亮闪一下再被下一拍轮询熄灭。
      if (!g_hovering && pt.y >= HoverTopLimit()) {
        g_hovering = true;
        RepaintLyric();
      }
      UpdateHotFromPoint(pt);
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
        if (g_popup == PopupKind::Volume) {
          // 音量面板:滑条区域开始拖动,其余点击吞掉。
          const RECT tr = TrackRect();
          if (pt.x >= tr.left - S(14) && pt.x <= tr.right + S(14) &&
              pt.y >= tr.top - S(6) && pt.y <= tr.bottom + S(6)) {
            g_sliderDragging = true;
            SetCapture(hwnd);
            SetVolumeAndNotify(VolumeFromY(pt.y));
          }
          return 0;
        }
        // 设备行内的接续箭头(↓ 接回本机 / ↑ 推到该设备):优先于整行
        // 点击 —— 命中就只发 handoff 事件,不切换控制目标(与 MINI 播放条
        // 小弹窗 _HandoffButton 的行为一致)。
        int handoffRow = -1;
        const int handoff = HitTestSwitchHandoff(pt, &handoffRow);
        if (handoff >= 0) {
          char buf[32];
          snprintf(buf, sizeof(buf),
                   handoff == 0 ? "switch_pull:%d" : "switch_push:%d",
                   handoffRow);
          FireEvent(buf);
          SetPopup(PopupKind::None);
          return 0;
        }
        // 队列列表:点击行跳播并收起弹窗。
        const int row = HitTestListRow(pt);
        if (row >= 0) {
          if (g_popup == PopupKind::Switch) {
            // 切换播放器:把选中行回传 Flutter(由它按 peerId 执行切换),
            // 并收起弹窗;Flutter 会在切换完成后回推最新状态与 toast。
            char buf[32];
            snprintf(buf, sizeof(buf), "switch_pick:%d", row);
            FireEvent(buf);
          } else {
            char buf[32];
            snprintf(buf, sizeof(buf), "queue_jump:%d", row);
            FireEvent(buf);
          }
          SetPopup(PopupKind::None);
        }
        return 0;
      }
      if (g_popup != PopupKind::None) {
        // 点弹窗外(含歌词区):收起弹窗。
        SetPopup(PopupKind::None);
        RepaintLyric();
        return 0;
      }
      // 其余区域:按下待判定——原地点击=开关主窗口,按住移动=拖动窗口。
      SetCapture(hwnd);
      g_pressPending = true;
      g_dragging = false;
      g_pressPt.x = GET_X_LPARAM(lParam);
      g_pressPt.y = GET_Y_LPARAM(lParam);
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
            case kBtnIdxPrev: FireEvent("previous"); break;
            case kBtnIdxPlay: FireEvent("toggle_play_pause"); break;
            case kBtnIdxNext: FireEvent("next"); break;
            case kBtnIdxMode: FireEvent("cycle_playback_mode"); break;
            case kBtnIdxVolume:
              SetPopup(g_popup == PopupKind::Volume ? PopupKind::None
                                                    : PopupKind::Volume);
              break;
            case kBtnIdxLike:
              // 乐观翻转:star/unstar 有网络往返,先立即变红/取消,
              // Dart 稍后推送真实状态,DesktopLyricUpdateState 会校正。
              g_liked = !g_liked;
              RepaintLyric();
              FireEvent("toggle_like");
              break;
            case kBtnIdxQueue:
              // 播放队列:toggle 展开/收起;数据由 Flutter 持续推送。
              SetPopup(g_popup == PopupKind::Queue ? PopupKind::None
                                                   : PopupKind::Queue);
              break;
            case kBtnIdxSwitch:
              // 切换播放器:在歌词窗【上方】展开自己的设备列表弹窗(内容与
              // MINI 播放条的小弹窗一致),而不是回到主窗口弹。首次展开时
              // 顺带请 Flutter 拉一次最新设备列表并推过来。
              // 再次点击同一按钮 = toggle 收起(用户明确要求)。
              SetPopup(g_popup == PopupKind::Switch ? PopupKind::None
                                                    : PopupKind::Switch);
              if (g_popup == PopupKind::Switch) {
                g_switchScroll = 0;
                FireEvent("switch_player_open");
              }
              break;
          }
        }
        return 0;
      }
      if (g_pressPending) {
        // 未超移动阈值的原地释放 = 单击:开关客户端主窗口
        // (开着→收进托盘,收着→弹回前台),由原生层拦截执行。
        g_pressPending = false;
        ReleaseCapture();
        FireEvent("toggle_main_window");
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
      g_pressPending = false;
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
    case WM_MOUSEWHEEL: {
      // 列表弹窗滚轮滚动(队列 / 切换播放器共用,行高与基准各自分派)。
      if (!PopupIsListLike()) return 0;
      const int delta = GET_WHEEL_DELTA_WPARAM(wParam);
      if (delta == 0) return 0;
      const int step = delta > 0 ? -3 : 3;
      const int maxScroll =
          std::max(0, ListItemCount() - ListVisibleRows());
      int& scroll = ListScroll();
      const int next = scroll + step;
      scroll = next < 0 ? 0 : (next > maxScroll ? maxScroll : next);
      RepaintLyric();
      return 0;
    }
    case WM_TIMER:
      // 跑马灯滚动重绘(仅超宽歌词时定时器存活)。
      if (wParam == kScrollTimerId) RepaintLyric();
      return 0;
    case kHoverWakeMsg:
      // 轮询线程检测到光标进出/移动,主线程重算悬停状态。
      UpdateHoverState();
      return 0;
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

// 创建 FontFamily 并校验 GetLastStatus:首选字体缺失(如精简版系统)时
// 降级到兜底字体。返回对象必非空(与原行为一致),状态由现有绘制路径容忍。
gd::FontFamily* CreateFamilyWithFallback(const wchar_t* preferred,
                                          const wchar_t* fallback) {
  auto* fam = new gd::FontFamily(preferred);
  if (fam->GetLastStatus() == gd::Ok) return fam;
  delete fam;
  return new gd::FontFamily(fallback);
}

void DesktopLyricInit(HINSTANCE instance) {
  if (g_hwnd) return;
  if (g_gdiplusToken == 0) {
    gd::GdiplusStartupInput input;
    gd::GdiplusStartup(&g_gdiplusToken, &input, nullptr);
    g_famUI = CreateFamilyWithFallback(L"Microsoft YaHei UI", L"Segoe UI");
    g_famIcon =
        CreateFamilyWithFallback(L"Segoe MDL2 Assets", L"Segoe UI Symbol");
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
  // 歌词变化 → 滚动循环从头开始(先停在句首 1.8s 再滚)。
  g_scrollCycle = 0;
  if (changed) RepaintLyric();
}

void DesktopLyricUpdateQueue(const DesktopLyricQueue& queue) {
  bool changed =
      g_queueItems.size() != queue.items.size() || g_queueIndex != queue.index;
  if (!changed) {
    for (size_t i = 0; i < queue.items.size(); ++i) {
      if (g_queueItems[i] != queue.items[i]) {
        changed = true;
        break;
      }
    }
  }
  if (!changed) return;
  const int oldH = g_popupH;
  g_queueItems = queue.items;
  g_queueIndex = queue.index;
  const int maxScroll = std::max(
      0, static_cast<int>(g_queueItems.size()) - kQueueMaxRows);
  if (g_queueScroll > maxScroll) g_queueScroll = maxScroll;
  // 队列弹窗高度随行数变化,展开中要同步窗口几何。
  g_popupH = S(PopupLogicalHeight(g_popup));
  SyncWindowHeight(oldH);
  RepaintLyric();
}

void DesktopLyricUpdateSwitchList(const DesktopLyricSwitchList& list) {
  bool changed = g_switchLoading != list.loading ||
                 g_switchItems.size() != list.items.size();
  if (!changed) {
    for (size_t i = 0; i < list.items.size(); ++i) {
      const LyricSwitchItem& a = g_switchItems[i];
      const DesktopLyricSwitchItem& b = list.items[i];
      if (a.title != b.title || a.subtitle != b.subtitle ||
          a.current != b.current || a.badge != b.badge ||
          a.canPull != b.canPull || a.canPush != b.canPush ||
          a.handoff != b.handoff || a.isRefresh != b.isRefresh ||
          a.icon != b.icon) {
        changed = true;
        break;
      }
    }
  }
  if (!changed) return;
  const int oldH = g_popupH;
  g_switchLoading = list.loading;
  g_switchItems.clear();
  g_switchItems.reserve(list.items.size());
  for (const DesktopLyricSwitchItem& it : list.items) {
    LyricSwitchItem item;
    item.title = it.title;
    item.subtitle = it.subtitle;
    item.badge = it.badge;
    item.current = it.current;
    item.canPull = it.canPull;
    item.canPush = it.canPush;
    item.handoff = it.handoff;
    item.isRefresh = it.isRefresh;
    item.icon = it.icon;
    g_switchItems.push_back(std::move(item));
  }
  const int maxScroll = std::max(
      0, static_cast<int>(g_switchItems.size()) - kSwitchMaxRows);
  if (g_switchScroll > maxScroll) g_switchScroll = maxScroll;
  // 弹窗高度随设备数变化,展开中要同步窗口几何(与队列弹窗同理)。
  g_popupH = S(PopupLogicalHeight(g_popup));
  SyncWindowHeight(oldH);
  RepaintLyric();
}

// 轮询线程主体:只做变化检测,状态计算/重绘全部在主线程执行。
// 用退出事件替代 Sleep:StopHoverPoll 置位后线程最多一个查询往返即返回。
DWORD WINAPI HoverPollProc(LPVOID) {
  while (g_hoverExitEvt && WaitForSingleObject(g_hoverExitEvt,
                                               kHoverPollMs) == WAIT_TIMEOUT) {
    if (!g_hoverRun || !g_visible || !g_hwnd) continue;
    POINT pt{};
    if (!GetCursorPos(&pt) || !ScreenToClient(g_hwnd, &pt)) continue;
    const bool inside = pt.x >= 0 && pt.x < g_curWidth &&
                        pt.y >= HoverTopLimit() && pt.y < TotalHeight();
    const bool moved = pt.x != g_lastPollPt.x || pt.y != g_lastPollPt.y;
    // 进出窗口边界变化,或悬停中发生移动,才唤醒主线程(空闲零消息)。
    if (inside != g_lastPollInside || (inside && moved)) {
      g_lastPollInside = inside;
      g_lastPollPt = pt;
      PostMessage(g_hwnd, kHoverWakeMsg, 0, 0);
    }
  }
  return 0;
}

void StartHoverPoll() {
  if (g_hoverThread) return;
  if (!g_hoverExitEvt) {
    g_hoverExitEvt = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (!g_hoverExitEvt) return;
  } else {
    ResetEvent(g_hoverExitEvt);
  }
  g_hoverRun = true;
  g_lastPollPt = POINT{};
  g_lastPollInside = false;
  g_hoverThread = CreateThread(nullptr, 0, HoverPollProc, nullptr, 0, nullptr);
}

void StopHoverPoll() {
  if (!g_hoverThread) return;
  g_hoverRun = false;
  if (g_hoverExitEvt) SetEvent(g_hoverExitEvt);
  // 事件驱动退出,线程微秒级返回;1s 等不到属极端异常(调度饿死级),
  // 也绝不 TerminateThread——强杀可能死在持有 GDI+/win32k 内部锁的任意点,
  // 直接进程级风险。事件已置位,线程随后自退出,句柄照常关闭。
  WaitForSingleObject(g_hoverThread, 1000);
  CloseHandle(g_hoverThread);
  g_hoverThread = nullptr;
}

void DesktopLyricSetVisible(bool visible) {
  g_visible = visible;
  if (!g_hwnd) return;
  if (visible) {
    ShowWindow(g_hwnd, SW_SHOWNOACTIVATE);
    SetWindowPos(g_hwnd, HWND_TOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    StartHoverPoll();
    RepaintLyric();
  } else {
    StopHoverPoll();
    g_hovering = false;
    g_hotButton = -1;
    g_hotRow = -1;
    g_sliderDragging = false;
    SetPopup(PopupKind::None);
    UpdateScrollTimer(false);
    ShowWindow(g_hwnd, SW_HIDE);
  }
}

bool DesktopLyricIsVisible() { return g_visible; }

void DesktopLyricShutdown() {
  StopHoverPoll();
  if (g_hoverExitEvt) {
    CloseHandle(g_hoverExitEvt);
    g_hoverExitEvt = nullptr;
  }
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
  delete g_fontBadge;
  g_fontBadge = nullptr;
  delete g_famUI;
  g_famUI = nullptr;
  delete g_famIcon;
  g_famIcon = nullptr;
  if (g_gdiplusToken != 0) {
    gd::GdiplusShutdown(g_gdiplusToken);
    g_gdiplusToken = 0;
  }
}

