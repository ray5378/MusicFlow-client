#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "tray.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  // 托盘图标点击(WM_TRAYICON)与托盘菜单命令(WM_COMMAND)在窗口过程层处理：
  // 由 DispatchMessage 稳定投递，不依赖 main 消息循环的 GetMessage 过滤
  //（过滤版本在部分 Windows 环境左右键完全不响应）。
  if (TrayHandleMessage(hwnd, message, wparam, lparam)) {
    return 0;
  }

  switch (message) {
    case WM_CLOSE:
      ShowWindow(hwnd, SW_HIDE);
      return 0;

    case WM_SYSCOMMAND:
      // 拦截「最小化」：让窗口缩到系统托盘(SW_HIDE)，而不是停在任务栏。
      // 否则点最小化按钮只是普通任务栏最小化，与托盘「缩小状态」割裂，
      // 用户感知为「托盘缩小完全无法使用」。
      if ((wparam & 0xFFF0) == SC_MINIMIZE) {
        ShowWindow(hwnd, SW_HIDE);
        return 0;
      }
      break;

    case WM_TRAY_COMMAND: {
      // Forward tray commands to Dart via platform channel
      std::string method;
      switch (wparam) {
        case TRAY_PLAY_PAUSE: method = "toggle_play_pause"; break;
        case TRAY_PREV: method = "previous"; break;
        case TRAY_NEXT: method = "next"; break;
        case TRAY_LYRICS: method = "toggle_status_lyrics"; break;
        default: return 0;
      }
      if (flutter_controller_ && flutter_controller_->engine()) {
        auto* messenger = flutter_controller_->engine()->messenger();
        if (messenger) {
          // Send as BasicMessageChannel message (raw string)
          std::vector<uint8_t> data(method.begin(), method.end());
          messenger->Send("com.musicflow.app/tray", data.data(), data.size());
        }
      }
      return 0;
    }

    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
