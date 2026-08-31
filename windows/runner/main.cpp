#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter_windows.h>
#include <windows.h>

#include <algorithm>
#include <string>

#include "desktop_lyric.h"
#include "flutter_window.h"
#include "tray.h"
#include "utils.h"

static NOTIFYICONDATAW g_nid = {};
static HMENU g_tray_menu = nullptr;

static void AddTrayIcon(HWND hwnd) {
  g_nid.cbSize = sizeof(NOTIFYICONDATAW);
  g_nid.hWnd = hwnd;
  g_nid.uID = TRAY_ICON_ID;
  g_nid.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  g_nid.uCallbackMessage = WM_TRAYICON;
  g_nid.hIcon = LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(101));
  wcscpy_s(g_nid.szTip, L"MusicFlow");
  if (!Shell_NotifyIconW(NIM_ADD, &g_nid)) {
    // 已有同 ID 图标（重启后残留）时用 NIM_MODIFY 接管，避免托盘无图标。
    Shell_NotifyIconW(NIM_MODIFY, &g_nid);
  }
}

static void RemoveTrayIcon() {
  Shell_NotifyIconW(NIM_DELETE, &g_nid);
}

static void ShowTrayMenu(HWND hwnd) {
  POINT pt;
  GetCursorPos(&pt);

  if (g_tray_menu) DestroyMenu(g_tray_menu);
  g_tray_menu = CreatePopupMenu();
  AppendMenuW(g_tray_menu, MF_STRING, TRAY_PLAY_PAUSE, L"暂停/播放(&P)");
  AppendMenuW(g_tray_menu, MF_STRING, TRAY_PREV, L"上一首(&V)");
  AppendMenuW(g_tray_menu, MF_STRING, TRAY_NEXT, L"下一首(&N)");
  AppendMenuW(g_tray_menu, MF_SEPARATOR, 0, nullptr);
  // 主窗口可见(正常显示或在任务栏最小化)时画 √;仅在「隐藏到托盘」时才无 √。
  const UINT showFlags =
      MF_STRING |
      ((IsWindowVisible(hwnd) || IsIconic(hwnd)) ? MF_CHECKED : MF_UNCHECKED);
  AppendMenuW(g_tray_menu, showFlags, TRAY_SHOW, L"显示窗口(&S)");
  // 桌面歌词开启时在菜单项前画 √(与浮窗显隐状态同步)。
  const UINT lyricsFlags =
      MF_STRING | (DesktopLyricIsVisible() ? MF_CHECKED : MF_UNCHECKED);
  AppendMenuW(g_tray_menu, lyricsFlags, TRAY_LYRICS, L"显示桌面歌词(&L)");
  AppendMenuW(g_tray_menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(g_tray_menu, MF_STRING, TRAY_QUIT, L"退出(&X)");

  // 先把窗口设为前台再弹菜单，否则 Windows 前台规则会立刻关闭弹出菜单。
  SetForegroundWindow(hwnd);
  TrackPopupMenu(g_tray_menu, TPM_RIGHTALIGN | TPM_BOTTOMALIGN,
                 pt.x, pt.y, 0, hwnd, nullptr);
  PostMessage(hwnd, WM_NULL, 0, 0);
}

void TrayInit(HWND hwnd) {
  AddTrayIcon(hwnd);
}

void TrayShutdown() {
  RemoveTrayIcon();
  if (g_tray_menu) {
    DestroyMenu(g_tray_menu);
    g_tray_menu = nullptr;
  }
}

void TraySetTooltip(const std::wstring& tip) {
  if (!g_nid.hWnd) return;
  // 空文本恢复默认应用名;非空时用于显示「状态栏歌词」当前行。
  // szTip 是 WCHAR[128],超出部分截断,末尾补 '\0'。
  const std::wstring& text = tip.empty() ? L"MusicFlow" : tip;
  const size_t copy_len = text.size() < 127 ? text.size() : 127;
  text.copy(g_nid.szTip, copy_len);
  g_nid.szTip[copy_len] = L'\0';
  g_nid.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  Shell_NotifyIconW(NIM_MODIFY, &g_nid);
}

bool TrayHandleMessage(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam) {
  if (message == WM_TRAYICON) {
    if (lParam == WM_LBUTTONUP || lParam == WM_LBUTTONDBLCLK) {
      // 从托盘恢复：窗口可能在托盘中隐藏(SW_HIDE)或最小化，统一 SW_RESTORE。
      if (!IsWindowVisible(hwnd) || IsIconic(hwnd)) {
        ShowWindow(hwnd, SW_RESTORE);
      }
      SetForegroundWindow(hwnd);
    } else if (lParam == WM_RBUTTONUP) {
      ShowTrayMenu(hwnd);
    }
    return true;
  }

  if (message == WM_COMMAND) {
    WORD cmd = LOWORD(wParam);
    switch (cmd) {
      case TRAY_SHOW:
        ShowWindow(hwnd, SW_RESTORE);
        SetForegroundWindow(hwnd);
        return true;
      case TRAY_PLAY_PAUSE:
      case TRAY_PREV:
      case TRAY_NEXT:
      case TRAY_LYRICS:
        // Forward to Flutter window as custom message.
        PostMessage(hwnd, WM_TRAY_COMMAND, cmd, 0);
        return true;
      case TRAY_QUIT:
        TrayShutdown();
        // SetQuitOnClose(false) 时 WM_DESTROY 不会自动 PostQuitMessage，
        // 必须手动结束消息循环，否则进程残留。
        DestroyWindow(hwnd);
        PostQuitMessage(0);
        return true;
      default:
        return false;
    }
  }

  return false;
}

namespace {

// 自适应默认窗口大小的等比基准：3840x2160 屏幕下默认窗口为 2720x1730。
// 该基准的选取原则是让首页「为你推荐」(8 张歌单卡片一行)在宽、高上都完整显示。
constexpr double kAnchorScreenWidth = 3840.0;
constexpr double kAnchorScreenHeight = 2160.0;
constexpr double kAnchorWindowWidth = 2720.0;
constexpr double kAnchorWindowHeight = 1730.0;
// 下限兜底：极低分辨率屏幕也避免默认窗口小到不可用。
constexpr int kMinDefaultWindowWidth = 1000;
constexpr int kMinDefaultWindowHeight = 640;

// 按目标显示器分辨率计算默认窗口大小(逻辑像素)。
// Create 内部会用同一块屏幕的 DPI 再放大到物理像素,这里直接返回逻辑尺寸即可。
Win32Window::Size ComputeDefaultWindowSize(const Win32Window::Point& origin) {
  const POINT pt = {static_cast<LONG>(origin.x), static_cast<LONG>(origin.y)};
  HMONITOR monitor = MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST);
  MONITORINFO mi{};
  mi.cbSize = sizeof(mi);
  if (GetMonitorInfoW(monitor, &mi)) {
    const double scale = FlutterDesktopGetDpiForMonitor(monitor) / 96.0;
    const double screenW = (mi.rcMonitor.right - mi.rcMonitor.left) / scale;
    const double screenH = (mi.rcMonitor.bottom - mi.rcMonitor.top) / scale;
    int w = static_cast<int>(screenW * (kAnchorWindowWidth / kAnchorScreenWidth) + 0.5);
    int h = static_cast<int>(screenH * (kAnchorWindowHeight / kAnchorScreenHeight) + 0.5);
    w = std::min(std::max(w, kMinDefaultWindowWidth), static_cast<int>(screenW));
    h = std::min(std::max(h, kMinDefaultWindowHeight), static_cast<int>(screenH));
    return Win32Window::Size(w, h);
  }
  // 取不到监视器信息(异常路径):回退到历史默认值。
  return Win32Window::Size(1280, 720);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  // 默认窗口大小自适应：以「3840x2160 屏 → 2720x1730」为基准做等比换算。
  // 选这个基准的出发点是要让首页「为你推荐」整类(8 张歌单)在宽/高上都完整
  // 显示 —— 宽刚好铺下 8 卡+留白,高刚好放下标题+歌单行。其它分辨率按同比例
  // 推得默认值。用户一旦自己拖过窗口,后续以注册表保存的尺寸为准
  // (RestoreWindowFrame 优先级更高),这里的默认只在"从未设置过"时生效。
  Win32Window::Size size = ComputeDefaultWindowSize(origin);
  if (!window.Create(L"MusicFlow", origin, size)) {
    return EXIT_FAILURE;
  }

  window.SetQuitOnClose(false);

  HWND hwnd = window.GetHandle();
  TrayInit(hwnd);
  // 桌面歌词浮窗:无边框置顶悬浮窗,默认隐藏,由 Flutter 端开关控制。
  DesktopLyricInit(instance);

  // 托盘图标消息(WM_TRAYICON)与托盘菜单命令(WM_COMMAND)统一在窗口过程
  // (flutter_window.cpp)里处理；这里只做标准消息泵，不再在 GetMessage 层
  // 过滤拦截——过滤版本在部分 Windows 环境下左右键完全不响应。
  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  TrayShutdown();
  DesktopLyricShutdown();

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
