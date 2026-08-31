#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <optional>
#include <string>
#include <variant>

#include "desktop_lyric.h"
#include "flutter/generated_plugin_registrant.h"
#include "tray.h"

namespace {

// UTF-8 -> UTF-16 helper for forwarding tooltip text to the tray icon.
std::wstring Utf8ToUtf16(const std::string& utf8) {
  if (utf8.empty()) return L"";
  const int size = MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                       static_cast<int>(utf8.size()), nullptr, 0);
  if (size <= 0) return L"";
  std::wstring result(size, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                      &result[0], size);
  return result;
}

}  // namespace

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

  // 窗口控制通道:客户端自绘标题栏(关闭/最小化/最大化/拖拽)与
  // 托盘「状态栏歌词」tooltip 均通过该通道与原生层交互。
  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "com.musicflow.app/window",
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        HandleWindowMethod(call, std::move(result));
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::HandleWindowMethod(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  HWND hwnd = GetHandle();
  const std::string& method = call.method_name();

  if (method == "minimize") {
    // 自绘标题栏的「缩小」按钮:缩到任务栏(不经过 WM_SYSCOMMAND SC_MINIMIZE,
    // 那里被拦截为隐藏到托盘)。
    ShowWindow(hwnd, SW_MINIMIZE);
    result->Success();
    return;
  }
  if (method == "maximize_toggle") {
    if (IsZoomed(hwnd)) {
      ShowWindow(hwnd, SW_RESTORE);
    } else {
      ShowWindow(hwnd, SW_MAXIMIZE);
    }
    result->Success();
    return;
  }
  if (method == "close") {
    // 关闭按钮:隐藏窗口到托盘(与 WM_CLOSE 现有行为一致,应用继续在后台播放)。
    PostMessage(hwnd, WM_CLOSE, 0, 0);
    result->Success();
    return;
  }
  if (method == "start_move") {
    // 无系统标题栏时,自绘标题栏拖拽需要手动进入 HTCAPTION 移动循环。
    ReleaseCapture();
    SendMessage(hwnd, WM_NCLBUTTONDOWN, HTCAPTION, 0);
    result->Success();
    return;
  }
  if (method == "set_tray_tooltip") {
    // 任务栏/托盘歌词:把当前歌词行写进托盘 tooltip(空文本恢复默认应用名)。
    std::wstring tip;
    // Flutter Windows 嵌入器的 MethodCall::arguments() 返回 const T*(指针),
    // 需要先解引用再访问 variant;不能用 `&call.arguments()`(对临时指针取址 → C2102)。
    if (const flutter::EncodableValue* arguments = call.arguments()) {
      if (std::holds_alternative<flutter::EncodableMap>(*arguments)) {
        const auto& argsMap = std::get<flutter::EncodableMap>(*arguments);
        const auto it = argsMap.find(flutter::EncodableValue("text"));
        if (it != argsMap.end()) {
          if (const auto* text = std::get_if<std::string>(&it->second)) {
            tip = Utf8ToUtf16(*text);
          }
        }
      }
    }
    TraySetTooltip(tip);
    result->Success();
    return;
  }
  if (method == "set_desktop_lyric_text") {
    // 桌面歌词浮窗:更新歌词文本(空文本清空;窗口自适应大小重绘)。
    std::wstring text;
    if (const flutter::EncodableValue* arguments = call.arguments()) {
      if (std::holds_alternative<flutter::EncodableMap>(*arguments)) {
        const auto& argsMap = std::get<flutter::EncodableMap>(*arguments);
        const auto it = argsMap.find(flutter::EncodableValue("text"));
        if (it != argsMap.end()) {
          if (const auto* s = std::get_if<std::string>(&it->second)) {
            text = Utf8ToUtf16(*s);
          }
        }
      }
    }
    DesktopLyricSetText(text);
    result->Success();
    return;
  }
  if (method == "set_desktop_lyric_visible") {
    // 桌面歌词浮窗:显示/隐藏(不抢焦点)。
    bool visible = false;
    if (const flutter::EncodableValue* arguments = call.arguments()) {
      if (std::holds_alternative<flutter::EncodableMap>(*arguments)) {
        const auto& argsMap = std::get<flutter::EncodableMap>(*arguments);
        const auto it = argsMap.find(flutter::EncodableValue("visible"));
        if (it != argsMap.end()) {
          if (const auto* b = std::get_if<bool>(&it->second)) {
            visible = *b;
          }
        }
      }
    }
    DesktopLyricSetVisible(visible);
    result->Success();
    return;
  }

  result->NotImplemented();
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
