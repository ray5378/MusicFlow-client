#ifndef MUSICFLOW_DESKTOP_LYRIC_H_
#define MUSICFLOW_DESKTOP_LYRIC_H_

#include <string>
#include <vector>
// 独立语法检查(Desktop Lyric Guard 的裸 cl /Zs)不经过 Flutter CMake 的
// 全局定义,须自带 NOMINMAX,否则 windows.h 的 min/max 宏撞 std::max/min。
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

// Native desktop lyric overlay window.
// Always-on-top, borderless, translucent, draggable with the mouse,
// right-click menu to hide.
// 两行显示(歌名-歌手 / 当前行歌词);鼠标悬停右缘浮出控制按钮:
// 上一首/播放暂停/下一首/播放模式/喜欢/播放队列(列表弹窗)/音量(滑条弹窗)/
// 切换播放器(设备列表弹窗,在歌词窗上方展开,内容与 MINI 播放条小弹窗一致)。
// 状态由 Flutter 推送(DesktopLyricUpdateState 等),按钮事件经
// DesktopLyricEventCallback 回传 Flutter(与托盘共用 tray 字符串通道)。

// 按钮事件回调:msg 为字符串协议消息
// ("previous"/"next"/"toggle_play_pause"/"cycle_playback_mode"/
//  "toggle_like"/"volume:0.68"/"queue_jump:3"/
//  "switch_player_open"(展开设备弹窗,请求 Flutter 拉取并推送列表)/
//  "switch_pick:2"(选中第 2 行设备,由 Flutter 执行切换)/
//  "switch_pull:2"(第 2 行设备:接回本机,↓)/
//  "switch_push:2"(第 2 行设备:推到该设备,↑)/
//  "switch_close"(设备弹窗收起:点按钮 toggle/选行/搬移/移出悬停区;
//    Flutter 侧据此停掉「正在播放」实时刷新循环))。
typedef void (*DesktopLyricEventCallback)(const char* msg);

// 桌面歌词浮窗完整显示状态(Flutter → Native)。
struct DesktopLyricState {
  std::wstring song;    // 歌名
  std::wstring artist;  // 歌手(可空)
  std::wstring lyric;   // 当前歌词行(空则显示 MusicFlow)
  bool playing = false;
  bool liked = false;
  int mode = 1;  // 0=shuffle 1=repeatAll 2=repeatOne 3=order
  double volume = 0.8;
  // 歌词行填充色(Flutter 推送,固定暖黄 0xFFC233,不随封面变化)。
  COLORREF lyricColor = RGB(240, 149, 149);
};

// 播放队列弹窗数据(Flutter → Native)。items 为已组好的单行显示文本
// (歌名 — 歌手,Flutter 侧负责截断外的一切格式),index 为当前曲下标。
struct DesktopLyricQueue {
  std::vector<std::wstring> items;
  int index = -1;
};

// 「切换播放器」弹窗数据(Flutter → Native):按当前控制目标排好序的设备
// 列表(本机在最前,与 MINI 播放条小弹窗同序),cur 标记当前正在控制的那台。
//
// 2026-09-10 补齐「与 MINI 弹窗同款」的行内元素(用户反馈歌词窗少了
// DLNA 设备行的功能):
//   - badge:行内小标签文本(如 "DLNA"/"群组"),空则不画;
//   - canPull/canPush:该设备是否有可接续的「现场」——
//     与 MUSICFlow 客户端 `PeerCastRow` 的 canPull/canPush 同语义
//     (canPull=设备队列非空且播放中;canPush=本机非投屏态且本机队列非空);
//   - 画成两支箭头按钮:↓=接回本机(拉),↑=推到音箱(推),置灰表示不可用。
//
// handoff 与 canPull/canPush 是**两件事**:handoff 决定画不画那两支箭头,
// canPull/canPush 只决定亮不亮。早期用 `canPull || canPush` 兼作显示条件,
// 两支都不可用时整块箭头直接消失 —— 用户看到的「歌词窗比 MINI 少功能」
// 就是这个(2026-09-10)。MINI 弹窗的设备行是**永远**有两支箭头的。
struct DesktopLyricSwitchItem {
  std::wstring title;     // 设备名(本机为「本机播放」)
  std::wstring subtitle;  // 状态副标题(投屏中/正在播放曲目/离线…)
  std::wstring badge;     // 设备类型小徽章(本机行留空;DLNA/群组…)
  bool current = false;   // 是否为当前控制目标
  bool canPull = false;   // 可「接回本机」(↓ 可用)
  bool canPush = false;   // 可「推到该设备」(↑ 可用)
  bool handoff = false;   // 是否画行内的两支接续箭头(仅远端设备行)
  bool isRefresh = false; // 「刷新设备列表」行(点击只回传 switch_pick:N,
                          // 由 Dart 重拉列表;无徽章/箭头/高亮选中语义)
  int icon = 0;           // 行首图标:0=无(小圆点兜底) 1=耳机(本机)
                          // 2=基站(DLNA) 3=人群(群组) 4=刷新(刷新行);
                          // 与 MINI 弹窗 PeerCastRow/MusicFlowActionRow 同款
};

struct DesktopLyricSwitchList {
  std::vector<DesktopLyricSwitchItem> items;
  bool loading = false;   // 正在拉取设备列表(空列表时显示「正在加载…」)
};

void DesktopLyricInit(HINSTANCE instance);
void DesktopLyricSetEventCallback(DesktopLyricEventCallback callback);
void DesktopLyricUpdateState(const DesktopLyricState& state);
void DesktopLyricUpdateQueue(const DesktopLyricQueue& queue);
void DesktopLyricUpdateSwitchList(const DesktopLyricSwitchList& list);
void DesktopLyricSetVisible(bool visible);
// 供托盘菜单在「显示桌面歌词」项前画 √:返回当前开关状态。
bool DesktopLyricIsVisible();
void DesktopLyricShutdown();

#endif  // MUSICFLOW_DESKTOP_LYRIC_H_
