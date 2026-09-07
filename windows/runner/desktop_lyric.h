#ifndef MUSICFLOW_DESKTOP_LYRIC_H_
#define MUSICFLOW_DESKTOP_LYRIC_H_

#include <string>
#include <windows.h>

// Native desktop lyric overlay window.
// Always-on-top, borderless, translucent, draggable with the mouse,
// right-click menu to hide.
// 两行显示(歌名-歌手 / 当前行歌词);鼠标悬停右缘浮出控制按钮:
// 上一首/播放暂停/下一首/播放模式/音量(带滑条弹窗)/喜欢。
// 状态由 Flutter 推送(DesktopLyricUpdateState),按钮事件经
// DesktopLyricEventCallback 回传 Flutter(与托盘共用 tray 字符串通道)。

// 按钮事件回调:msg 为字符串协议消息
// ("previous"/"next"/"toggle_play_pause"/"cycle_playback_mode"/
//  "toggle_like"/"volume:0.68")。
typedef void (*DesktopLyricEventCallback)(const char* msg);

// 桌面歌词浮窗完整显示状态(Flutter → Native)。
struct DesktopLyricState {
  std::wstring song;    // 歌名
  std::wstring artist;  // 歌手(可空)
  std::wstring lyric;   // 当前歌词行(空则显示 MusicFlow)
  bool playing = false;
  bool liked = false;
  int mode = 1;  // 0=shuffle 1=repeatAll 2=repeatOne
  double volume = 0.8;
  // 歌词行填充色(Flutter 推送,随 MINI 播放器歌词栏 accent 同步变化)。
  COLORREF lyricColor = RGB(240, 149, 149);
};

void DesktopLyricInit(HINSTANCE instance);
void DesktopLyricSetEventCallback(DesktopLyricEventCallback callback);
void DesktopLyricUpdateState(const DesktopLyricState& state);
void DesktopLyricSetVisible(bool visible);
// 供托盘菜单在「显示桌面歌词」项前画 √:返回当前开关状态。
bool DesktopLyricIsVisible();
void DesktopLyricShutdown();

#endif  // MUSICFLOW_DESKTOP_LYRIC_H_
