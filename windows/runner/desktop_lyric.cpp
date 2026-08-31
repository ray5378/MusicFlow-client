#include "desktop_lyric.h"

#include <windowsx.h>

#include <algorithm>

namespace {

constexpr wchar_t kLyricWindowClass[] = L"MusicFlowDesktopLyric";
constexpr wchar_t kRegKey[] = L"Software\\MusicFlow";
constexpr wchar_t kRegPosX[] = L"LyricX";
constexpr wchar_t kRegPosY[] = L"LyricY";

// Font / layout constants.
constexpr int kFontSize = 24;        // 歌词字号(逻辑像素)
constexpr int kWindowWidth = 520;    // 窗口固定宽度(不随文本伸缩)
constexpr int kWindowHeight = 84;    // 窗口固定高度
constexpr int kPaddingX = 26;        // 水平左对齐内边距
constexpr int kShadowOffset = 2;     // 文字阴影偏移
constexpr BYTE kWindowAlpha = 210;   // 整窗透明度(0-255)
constexpr int kCornerRadius = 12;    // 圆角半径
constexpr COLORREF kBgColor = RGB(28, 28, 34);      // 深色圆角背景
constexpr COLORREF kTextColor = RGB(255, 255, 255); // 歌词主色
constexpr COLORREF kShadowColor = RGB(0, 0, 0);     // 阴影色

HWND g_hwnd = nullptr;
HFONT g_font = nullptr;
std::wstring g_text;
bool g_visible = false;
bool g_dragging = false;
POINT g_dragOffset{};

void SaveLyricPos() {
  if (!g_hwnd) return;
  RECT rc{};
  GetWindowRect(g_hwnd, &rc);
  RegSetKeyValueW(HKEY_CURRENT_USER, kRegKey, kRegPosX, REG_DWORD, &rc.left,
                  sizeof(DWORD));
  RegSetKeyValueW(HKEY_CURRENT_USER, kRegKey, kRegPosY, REG_DWORD, &rc.top,
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
  // Only restore when the saved point is inside the current work area.
  RECT wa{};
  SystemParametersInfoW(SPI_GETWORKAREA, 0, &wa, 0);
  if (static_cast<int>(savedX) >= wa.left &&
      static_cast<int>(savedX) < wa.right &&
      static_cast<int>(savedY) >= wa.top &&
      static_cast<int>(savedY) < wa.bottom) {
    *x = static_cast<int>(savedX);
    *y = static_cast<int>(savedY);
  }
  // 窗口固定大小(520x84)后,旧保存位置可能使窗口部分超出工作区,clamp 回来。
  if (*x + kWindowWidth > wa.right) *x = wa.right - kWindowWidth - 80;
  if (*y + kWindowHeight > wa.bottom) *y = wa.bottom - kWindowHeight - 40;
  if (*x < wa.left) *x = wa.left;
  if (*y < wa.top) *y = wa.top;
}

// 窗口大小固定(不随歌词文本伸缩,避免长度跳动);歌词更新仅触发重绘。
void RepaintLyric() {
  if (g_hwnd) InvalidateRect(g_hwnd, nullptr, FALSE);
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
      // Rounded translucent dark background.
      HRGN bg = CreateRoundRectRgn(0, 0, w + 1, h + 1, kCornerRadius,
                                   kCornerRadius);
      HBRUSH brush = CreateSolidBrush(kBgColor);
      FillRgn(hdc, bg, brush);
      DeleteObject(brush);
      DeleteObject(bg);
      // Lyric text: black shadow + white main text.
      // 水平左对齐(kPaddingX 起),垂直方向在窗口内上下居中。
      if (!g_text.empty()) {
        SetBkMode(hdc, TRANSPARENT);
        HFONT old = static_cast<HFONT>(SelectObject(hdc, g_font));
        SIZE sz{};
        GetTextExtentPoint32W(hdc, g_text.c_str(),
                              static_cast<int>(g_text.size()), &sz);
        const int y = (h - sz.cy) / 2;
        // Shadow pass.
        SetTextColor(hdc, kShadowColor);
        TextOutW(hdc, kPaddingX + kShadowOffset, y + kShadowOffset,
                 g_text.c_str(), static_cast<int>(g_text.size()));
        // Main pass.
        SetTextColor(hdc, kTextColor);
        TextOutW(hdc, kPaddingX, y, g_text.c_str(),
                 static_cast<int>(g_text.size()));
        SelectObject(hdc, old);
      }
      EndPaint(hwnd, &ps);
      return 0;
    }
    case WM_ERASEBKGND:
      // Prevent flicker; background is drawn in WM_PAINT.
      return 1;
    case WM_LBUTTONDOWN: {
      SetCapture(hwnd);
      g_dragging = true;
      g_dragOffset.x = GET_X_LPARAM(lParam);
      g_dragOffset.y = GET_Y_LPARAM(lParam);
      return 0;
    }
    case WM_MOUSEMOVE: {
      if (g_dragging) {
        POINT cur{};
        GetCursorPos(&cur);
        SetWindowPos(hwnd, nullptr, cur.x - g_dragOffset.x,
                     cur.y - g_dragOffset.y, 0, 0,
                     SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
      }
      return 0;
    }
    case WM_LBUTTONUP: {
      if (g_dragging) {
        g_dragging = false;
        ReleaseCapture();
        SaveLyricPos();
      }
      return 0;
    }
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
      if (cmd == 1) DesktopLyricSetVisible(false);
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

  g_font = CreateFontW(-kFontSize, 0, 0, 0, FW_BOLD, FALSE, FALSE, FALSE,
                       DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                       CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                       DEFAULT_PITCH | FF_DONTCARE, L"Microsoft YaHei UI");

  // Default position: bottom-right of the work area (above the taskbar),
  // keep some margin from the edges (80/40) so it is not glued to the corner;
  // restored position from registry wins when it is still on-screen.
  RECT wa{};
  SystemParametersInfoW(SPI_GETWORKAREA, 0, &wa, 0);
  int x = wa.right - kWindowWidth - 80;
  int y = wa.bottom - kWindowHeight - 40;
  RestoreLyricPos(&x, &y);

  g_hwnd = CreateWindowExW(
      WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_LAYERED, kLyricWindowClass,
      L"MusicFlowLyric", WS_POPUP, x, y, kWindowWidth, kWindowHeight, nullptr,
      nullptr, instance, nullptr);
  if (!g_hwnd) return;
  SetLayeredWindowAttributes(g_hwnd, 0, kWindowAlpha, LWA_ALPHA);
}

void DesktopLyricSetText(const std::wstring& text) {
  if (g_text == text) return;
  g_text = text;
  RepaintLyric();
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
  if (g_font) {
    DeleteObject(g_font);
    g_font = nullptr;
  }
}
