#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

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
  AppendMenuW(g_tray_menu, MF_STRING, TRAY_SHOW, L"显示窗口(&S)");
  AppendMenuW(g_tray_menu, MF_STRING, TRAY_LYRICS, L"显示状态栏歌词(&L)");
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
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"MusicFlow", origin, size)) {
    return EXIT_FAILURE;
  }

  window.SetQuitOnClose(false);

  HWND hwnd = window.GetHandle();
  TrayInit(hwnd);

  // 托盘图标消息(WM_TRAYICON)与托盘菜单命令(WM_COMMAND)统一在窗口过程
  // (flutter_window.cpp)里处理；这里只做标准消息泵，不再在 GetMessage 层
  // 过滤拦截——过滤版本在部分 Windows 环境下左右键完全不响应。
  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  TrayShutdown();

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
