#pragma once

#include <windows.h>

// System tray constants shared between main.cpp (tray lifecycle) and
// flutter_window.cpp (tray message handling in the window procedure).
static constexpr UINT WM_TRAYICON = WM_USER + 1;
static constexpr UINT WM_TRAY_COMMAND = WM_USER + 2;
static constexpr UINT TRAY_SHOW = 1001;
static constexpr UINT TRAY_QUIT = 1002;
static constexpr UINT TRAY_PLAY_PAUSE = 1003;
static constexpr UINT TRAY_PREV = 1004;
static constexpr UINT TRAY_NEXT = 1005;
static constexpr UINT TRAY_LYRICS = 1006;
static constexpr UINT TRAY_ICON_ID = 1;

// Tray lifecycle (defined in main.cpp).
void TrayInit(HWND hwnd);
void TrayShutdown();

// Handles WM_TRAYICON (icon clicks) and WM_COMMAND (tray menu items) inside
// the window procedure. Returns true if the message was consumed.
//
// Why here instead of the main GetMessage loop: the loop-based version never
// triggered on some Windows setups (left/right click on the tray icon did
// nothing). DispatchMessage always delivers posted window messages to the
// window procedure, so handling here is the robust canonical pattern.
bool TrayHandleMessage(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam);
