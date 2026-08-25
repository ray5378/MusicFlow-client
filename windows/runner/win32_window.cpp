#include "win32_window.h"

#include <commctrl.h>
#include <dwmapi.h>
#include <flutter_windows.h>

#include "resource.h"

// SetWindowSubclass / DefSubclassProc live in Comctl32.dll.
#pragma comment(lib, "comctl32.lib")

namespace {

/// Window attribute that enables dark mode window decorations.
///
/// Redefined in case the developer's machine has a Windows SDK older than
/// version 10.0.22000.0.
/// See: https://docs.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

/// Registry key for app theme preference.
///
/// A value of 0 indicates apps should use dark mode. A non-zero or missing
/// value indicates apps should use light mode.
constexpr const wchar_t kGetPreferredBrightnessRegKey[] =
  L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr const wchar_t kGetPreferredBrightnessRegValue[] = L"AppsUseLightTheme";

// Registry key for remembering the window frame (position + size), so the
// width/height the user last set is preserved across launches.
constexpr const wchar_t kWindowFrameRegKey[] =
  L"Software\\MusicFlow\\MusicFlowClient";
constexpr const wchar_t kWindowFrameRegLeft[] = L"WindowLeft";
constexpr const wchar_t kWindowFrameRegTop[] = L"WindowTop";
constexpr const wchar_t kWindowFrameRegWidth[] = L"WindowWidth";
constexpr const wchar_t kWindowFrameRegHeight[] = L"WindowHeight";

// The number of Win32Window objects that currently exist.
static int g_active_window_count = 0;

using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);

// Scale helper to convert logical scaler values to physical using passed in
// scale factor
int Scale(int source, double scale_factor) {
  return static_cast<int>(source * scale_factor);
}

// Dynamically loads the |EnableNonClientDpiScaling| from the User32 module.
// This API is only needed for PerMonitor V1 awareness mode.
void EnableFullDpiSupportIfAvailable(HWND hwnd) {
  HMODULE user32_module = LoadLibraryA("User32.dll");
  if (!user32_module) {
    return;
  }
  auto enable_non_client_dpi_scaling =
      reinterpret_cast<EnableNonClientDpiScaling*>(
          GetProcAddress(user32_module, "EnableNonClientDpiScaling"));
  if (enable_non_client_dpi_scaling != nullptr) {
    enable_non_client_dpi_scaling(hwnd);
  }
  FreeLibrary(user32_module);
}

// 把当前窗口位置与大小写进注册表,供下次启动恢复。最小化/最大化时不保存,
// 避免把「还原/最大化」误记为正常窗口大小。
void SaveWindowFrame(HWND hwnd) {
  if (hwnd == nullptr || IsIconic(hwnd) || IsZoomed(hwnd)) {
    return;
  }
  RECT rect;
  if (!GetWindowRect(hwnd, &rect)) {
    return;
  }
  HKEY key = nullptr;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, kWindowFrameRegKey, 0, nullptr, 0,
                      KEY_SET_VALUE, nullptr, &key, nullptr) !=
      ERROR_SUCCESS) {
    return;
  }
  DWORD width = static_cast<DWORD>(rect.right - rect.left);
  DWORD height = static_cast<DWORD>(rect.bottom - rect.top);
  RegSetValueExW(key, kWindowFrameRegLeft, 0, REG_DWORD,
                 reinterpret_cast<const BYTE*>(&rect.left), sizeof(DWORD));
  RegSetValueExW(key, kWindowFrameRegTop, 0, REG_DWORD,
                 reinterpret_cast<const BYTE*>(&rect.top), sizeof(DWORD));
  RegSetValueExW(key, kWindowFrameRegWidth, 0, REG_DWORD,
                 reinterpret_cast<const BYTE*>(&width), sizeof(DWORD));
  RegSetValueExW(key, kWindowFrameRegHeight, 0, REG_DWORD,
                 reinterpret_cast<const BYTE*>(&height), sizeof(DWORD));
  RegCloseKey(key);
}

// 恢复上次保存的窗口位置与大小。仅当保存的矩形仍与某个屏幕相交时才应用,
// 避免显示器变更(拔掉外接屏)后窗口落到可见区域之外。
void RestoreWindowFrame(HWND hwnd) {
  if (hwnd == nullptr) {
    return;
  }
  HKEY key = nullptr;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, kWindowFrameRegKey, 0, KEY_QUERY_VALUE,
                    &key) != ERROR_SUCCESS) {
    return;
  }
  DWORD left = 0, top = 0, width = 0, height = 0;
  DWORD size = sizeof(DWORD);
  bool ok = RegQueryValueExW(key, kWindowFrameRegLeft, nullptr, nullptr,
                             reinterpret_cast<BYTE*>(&left), &size) ==
                ERROR_SUCCESS &&
            RegQueryValueExW(key, kWindowFrameRegTop, nullptr, nullptr,
                             reinterpret_cast<BYTE*>(&top), &size) ==
                ERROR_SUCCESS &&
            RegQueryValueExW(key, kWindowFrameRegWidth, nullptr, nullptr,
                             reinterpret_cast<BYTE*>(&width), &size) ==
                ERROR_SUCCESS &&
            RegQueryValueExW(key, kWindowFrameRegHeight, nullptr, nullptr,
                             reinterpret_cast<BYTE*>(&height), &size) ==
                ERROR_SUCCESS;
  RegCloseKey(key);
  if (!ok || width == 0 || height == 0) {
    return;
  }
  RECT rect{static_cast<LONG>(left),
            static_cast<LONG>(top),
            static_cast<LONG>(left) + static_cast<LONG>(width),
            static_cast<LONG>(top) + static_cast<LONG>(height)};
  if (MonitorFromRect(&rect, MONITOR_DEFAULTTONULL) == nullptr) {
    return;
  }
  MoveWindow(hwnd, rect.left, rect.top, rect.right - rect.left,
             rect.bottom - rect.top, TRUE);
}

// 计算鼠标(屏幕坐标)相对窗口边框的命中区域。无标题栏窗口在 WM_NCCALCSIZE
// 返回 0 后非客户区消失,系统默认的「按住边缘缩放」热区随之不可用 —— 这会让
// 窗口变成固定大小、无法用鼠标拉伸。这里按目标窗口所在监视器的 DPI 换算一个
// 稳定的边缘带(逻辑 6px),对四边四角返回沿用系统的 HT* 调整大小码;内部区域
// 一律回 HTCLIENT(内容交给客户端处理)。窗口最大化时由调用方跳过本函数。
//
// 动态加载 GetDpiForWindow(Windows 10 1607+),避免依赖编译环境的 SDK 版本。
LRESULT HitTestWindowEdges(HWND target, LPARAM lparam) {
  const int mouse_x = static_cast<int>(static_cast<short>(LOWORD(lparam)));
  const int mouse_y = static_cast<int>(static_cast<short>(HIWORD(lparam)));

  static UINT(WINAPI* s_get_dpi)(HWND) = nullptr;
  if (s_get_dpi == nullptr) {
    HMODULE user32 = GetModuleHandleW(L"User32.dll");
    if (user32 != nullptr) {
      s_get_dpi = reinterpret_cast<UINT(WINAPI*)(HWND)>(
          GetProcAddress(user32, "GetDpiForWindow"));
    }
  }
  const UINT dpi = s_get_dpi != nullptr ? s_get_dpi(target) : 96u;
  const LONG border = MulDiv(6, static_cast<int>(dpi), 96);

  RECT rc;
  if (!GetWindowRect(target, &rc)) {
    return HTCLIENT;
  }
  const bool on_left = mouse_x >= rc.left && mouse_x <= rc.left + border;
  const bool on_right = mouse_x >= rc.right - border;
  const bool on_top = mouse_y >= rc.top && mouse_y <= rc.top + border;
  const bool on_bottom = mouse_y >= rc.bottom - border;
  if (on_left && on_top) return HTTOPLEFT;
  if (on_right && on_top) return HTTOPRIGHT;
  if (on_left && on_bottom) return HTBOTTOMLEFT;
  if (on_right && on_bottom) return HTBOTTOMRIGHT;
  if (on_left) return HTLEFT;
  if (on_right) return HTRIGHT;
  if (on_top) return HTTOP;
  if (on_bottom) return HTBOTTOM;
  return HTCLIENT;
}

// Flutter 的渲染窗口以子窗口形式铺满整个客户区(见 SetChildContent)。当光标
// 位于其上时,Windows 会把 WM_NCHITTEST 先派发给这个子窗口而非顶层框架窗口,
// 因此仅在顶层处理边缘命中不一定生效 —— 这正是 1.0.25 里「窗口仍无法拉伸」
// 的根因。
//
// 注意:子窗口不能直接返回 HT* 缩放码。缩放模态循环会作用在「返回该码的窗口」
// 上,也就是这个子窗口;可子窗口铺满客户区、其左下角被顶层限制,而且顶层收到
// WM_SIZE 后会把子窗口 MoveWindow 拉回原样 —— 结果就是光标显示成可拉伸
// (HT* 已生效),但一拖就被拉回、根本拖不动(1.0.26 里只剩右下斜角勉强动)。
//
// 正确做法:命中落在顶层缩放边缘带时,子窗口返回 HTTRANSPARENT,让系统把命中
// 穿透到底下的顶层框架窗口(WS_THICKFRAME 仍在),由顶层自家的 WM_NCHITTEST
// 返回 HT* 缩放码,并在「顶层窗口」上开启尺寸模态循环 —— 缩放真正作用于整个
// 窗口,四条边和四个角都能稳定拉伸。内部区域由子窗口回 HTCLIENT,交给 Flutter。
LRESULT CALLBACK ChildWindowSubclassProc(HWND hwnd, UINT message,
                                         WPARAM wparam, LPARAM lparam,
                                         UINT_PTR /*idSubclass*/,
                                         DWORD_PTR /*dwRefData*/) {
  if (message == WM_NCHITTEST) {
    HWND root = GetAncestor(hwnd, GA_ROOT);
    if (root != nullptr && !IsZoomed(root)) {
      if (HitTestWindowEdges(root, lparam) != HTCLIENT) {
        // 落在顶层缩放边缘带:穿透给顶层框架窗口处理缩放。
        return HTTRANSPARENT;
      }
    }
    return HTCLIENT;  // 内部:内容归 Flutter。
  }
  return DefSubclassProc(hwnd, message, wparam, lparam);
}

}  // namespace

// Manages the Win32Window's window class registration.
class WindowClassRegistrar {
 public:
  ~WindowClassRegistrar() = default;

  // Returns the singleton registrar instance.
  static WindowClassRegistrar* GetInstance() {
    if (!instance_) {
      instance_ = new WindowClassRegistrar();
    }
    return instance_;
  }

  // Returns the name of the window class, registering the class if it hasn't
  // previously been registered.
  const wchar_t* GetWindowClass();

  // Unregisters the window class. Should only be called if there are no
  // instances of the window.
  void UnregisterWindowClass();

 private:
  WindowClassRegistrar() = default;

  static WindowClassRegistrar* instance_;

  bool class_registered_ = false;
};

WindowClassRegistrar* WindowClassRegistrar::instance_ = nullptr;

const wchar_t* WindowClassRegistrar::GetWindowClass() {
  if (!class_registered_) {
    WNDCLASS window_class{};
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClassName;
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    window_class.hbrBackground = 0;
    window_class.lpszMenuName = nullptr;
    window_class.lpfnWndProc = Win32Window::WndProc;
    RegisterClass(&window_class);
    class_registered_ = true;
  }
  return kWindowClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
  UnregisterClass(kWindowClassName, nullptr);
  class_registered_ = false;
}

Win32Window::Win32Window() {
  ++g_active_window_count;
}

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
}

bool Win32Window::Create(const std::wstring& title,
                         const Point& origin,
                         const Size& size) {
  Destroy();

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();

  const POINT target_point = {static_cast<LONG>(origin.x),
                              static_cast<LONG>(origin.y)};
  HMONITOR monitor = MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  double scale_factor = dpi / 96.0;

  HWND window = CreateWindow(
      window_class, title.c_str(), WS_OVERLAPPEDWINDOW,
      Scale(origin.x, scale_factor), Scale(origin.y, scale_factor),
      Scale(size.width, scale_factor), Scale(size.height, scale_factor),
      nullptr, nullptr, GetModuleHandle(nullptr), this);

  if (!window) {
    return false;
  }

  UpdateTheme(window);

  // 任务2:去掉 Windows 系统标题栏(WS_CAPTION)。
  // 保留 WS_THICKFRAME / WS_MINIMIZEBOX / WS_MAXIMIZEBOX,窗口仍可调整大小;
  // 关闭/最小化按钮改由客户端页面内自绘标题栏(WindowsTitleBar)提供。
  LONG_PTR style = GetWindowLongPtr(window, GWL_STYLE);
  style &= ~WS_CAPTION;
  SetWindowLongPtr(window, GWL_STYLE, style);
  SetWindowPos(window, nullptr, 0, 0, 0, 0,
               SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                   SWP_NOACTIVATE);

  // 恢复上次保存的窗口位置/大小(若无记录则保持默认 1280x720)。
  // 需在 OnCreate 之前执行,以便 Flutter 子窗口按恢复后的尺寸创建。
  RestoreWindowFrame(window);

  return OnCreate();
}

bool Win32Window::Show() {
  return ShowWindow(window_handle_, SW_SHOWNORMAL);
}

// static
LRESULT CALLBACK Win32Window::WndProc(HWND const window,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

    auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
    EnableFullDpiSupportIfAvailable(window);
    that->window_handle_ = window;
  } else if (Win32Window* that = GetThisFromHandle(window)) {
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT
Win32Window::MessageHandler(HWND hwnd,
                            UINT const message,
                            WPARAM const wparam,
                            LPARAM const lparam) noexcept {
  switch (message) {
    case WM_DESTROY:
      SaveWindowFrame(hwnd);
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;

    case WM_DPICHANGED: {
      auto newRectSize = reinterpret_cast<RECT*>(lparam);
      LONG newWidth = newRectSize->right - newRectSize->left;
      LONG newHeight = newRectSize->bottom - newRectSize->top;

      SetWindowPos(hwnd, nullptr, newRectSize->left, newRectSize->top, newWidth,
                   newHeight, SWP_NOZORDER | SWP_NOACTIVATE);

      return 0;
    }
    case WM_NCCALCSIZE:
      // 无边框窗口：移除标题栏(WS_CAPTION)后，系统仍会因保留 WS_THICKFRAME
      // 在窗口顶部绘制一条非客户区边框线(白/亮色细边，横贯整窗)。
      // 让客户区铺满整个窗口、裁掉这条白边；WS_THICKFRAME 仍在，
      // 调整大小的边缘热区不受影响。(Windows 11 下 DWM 仍提供圆角阴影。)
      return 0;

    case WM_EXITSIZEMOVE:
      // 拖拽/外框调整结束后才落盘,避免拖动过程中高频写注册表。
      SaveWindowFrame(hwnd);
      return 0;

    case WM_NCHITTEST: {
      if (IsZoomed(hwnd)) {
        break;  // 最大化:交给默认处理,无需边缘热区。
      }
      // 无标题栏(WS_CAPTION 被移除)且 WM_NCCALCSIZE 返回 0 后,非客户区不复存在,
      // 系统默认的「按住边缘缩放」热区也随之消失。这里按 DPI 换算边缘带,对四边
      // 四角返回 HT* 缩放码,恢复鼠标拖拽拉伸;子窗口铺满客户区时该消息改由
      // ChildWindowSubclassProc 拦截,此处兜底处理顶层直达的 WM_NCHITTEST。
      return HitTestWindowEdges(hwnd, lparam);
    }

    case WM_SIZE: {
      RECT rect = GetClientArea();
      if (child_content_ != nullptr) {
        // Size and position the child window.
        MoveWindow(child_content_, rect.left, rect.top, rect.right - rect.left,
                   rect.bottom - rect.top, TRUE);
      }
      return 0;
    }

    case WM_ACTIVATE:
      if (child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      return 0;

    case WM_DWMCOLORIZATIONCOLORCHANGED:
      UpdateTheme(hwnd);
      return 0;
  }

  return DefWindowProc(window_handle_, message, wparam, lparam);
}

void Win32Window::Destroy() {
  OnDestroy();

  if (window_handle_) {
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  SetParent(content, window_handle_);
  // 子窗口铺满整个客户区,会拦截边缘的 WM_NCHITTEST;套上子类化过程把边缘命中
  // 恢复为 HT* 缩放码(缩放作用于顶层框架),保证无论消息投递给哪一层窗口,
  // 鼠标都能正常拉伸窗口大小。
  SetWindowSubclass(content, &ChildWindowSubclassProc, 1, 0);
  RECT frame = GetClientArea();

  MoveWindow(content, frame.left, frame.top, frame.right - frame.left,
             frame.bottom - frame.top, true);

  SetFocus(child_content_);
}

RECT Win32Window::GetClientArea() {
  RECT frame;
  GetClientRect(window_handle_, &frame);
  return frame;
}

HWND Win32Window::GetHandle() {
  return window_handle_;
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

bool Win32Window::OnCreate() {
  // No-op; provided for subclasses.
  return true;
}

void Win32Window::OnDestroy() {
  // No-op; provided for subclasses.
}

void Win32Window::UpdateTheme(HWND const window) {
  DWORD light_mode;
  DWORD light_mode_size = sizeof(light_mode);
  LSTATUS result = RegGetValue(HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey,
                               kGetPreferredBrightnessRegValue,
                               RRF_RT_REG_DWORD, nullptr, &light_mode,
                               &light_mode_size);

  if (result == ERROR_SUCCESS) {
    BOOL enable_dark_mode = light_mode == 0;
    DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                          &enable_dark_mode, sizeof(enable_dark_mode));
  }
}
