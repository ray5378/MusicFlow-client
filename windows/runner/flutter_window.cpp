#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

static const UINT WM_TRAY_COMMAND = WM_USER + 2;
static const UINT TRAY_PLAY_PAUSE = 1003;
static const UINT TRAY_PREV = 1004;
static const UINT TRAY_NEXT = 1005;
static const UINT TRAY_LYRICS = 1006;

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

  switch (message) {
    case WM_CLOSE:
      ShowWindow(hwnd, SW_HIDE);
      return 0;

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
