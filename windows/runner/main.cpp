#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

// System tray constants
static const UINT WM_TRAYICON = WM_USER + 1;
static const UINT TRAY_SHOW = 1001;
static const UINT TRAY_QUIT = 1002;
static const UINT TRAY_PLAY_PAUSE = 1003;
static const UINT TRAY_PREV = 1004;
static const UINT TRAY_NEXT = 1005;
static const UINT TRAY_LYRICS = 1006;
static const UINT TRAY_ICON_ID = 1;
// Custom message to forward tray commands to Flutter window
static const UINT WM_TRAY_COMMAND = WM_USER + 2;

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
  Shell_NotifyIconW(NIM_ADD, &g_nid);
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

  SetForegroundWindow(hwnd);
  TrackPopupMenu(g_tray_menu, TPM_RIGHTALIGN | TPM_BOTTOMALIGN,
                 pt.x, pt.y, 0, hwnd, nullptr);
  PostMessage(hwnd, WM_NULL, 0, 0);
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
  AddTrayIcon(hwnd);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    if (msg.message == WM_TRAYICON) {
      if (msg.lParam == WM_LBUTTONUP) {
        ShowWindow(hwnd, SW_RESTORE);
        SetForegroundWindow(hwnd);
      } else if (msg.lParam == WM_RBUTTONUP) {
        ShowTrayMenu(hwnd);
      }
    } else if (msg.message == WM_COMMAND) {
      WORD cmd = LOWORD(msg.wParam);
      switch (cmd) {
        case TRAY_SHOW:
          ShowWindow(hwnd, SW_RESTORE);
          SetForegroundWindow(hwnd);
          break;
        case TRAY_PLAY_PAUSE:
        case TRAY_PREV:
        case TRAY_NEXT:
        case TRAY_LYRICS:
          // Forward to Flutter window as custom message
          PostMessage(hwnd, WM_TRAY_COMMAND, cmd, 0);
          break;
        case TRAY_QUIT:
          RemoveTrayIcon();
          if (g_tray_menu) DestroyMenu(g_tray_menu);
          DestroyWindow(hwnd);
          break;
      }
    } else {
      ::TranslateMessage(&msg);
      ::DispatchMessage(&msg);
    }
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
