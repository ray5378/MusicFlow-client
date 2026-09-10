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

// 全局 messenger 指针：OnCreate 时从 Flutter 引擎取到，供 NotifyWindowVisible
// 在窗口消息路径（WM_CLOSE/SC_MINIMIZE）与托盘恢复路径（main.cpp）发送可见性。
static flutter::BinaryMessenger* g_window_messenger = nullptr;
static HWND g_main_window = nullptr;  // 主窗口句柄(歌词栏单击开关主窗口用)

}  // namespace

void NotifyWindowVisible(bool visible) {
  if (!g_window_messenger) {
    return;
  }
  // 与 Dart 端 BasicMessageChannel<String>(StringCodec) 对应的原生发送：
  // 直接以 UTF-8 原始字节下发 "true"/"false"。仅当可见性真正翻转时再由
  // Dart 端 setMessageHandler 收到，未注册时会以 empty reply 安全返回。
  const std::string msg = visible ? "true" : "false";
  std::vector<uint8_t> data(msg.begin(), msg.end());
  g_window_messenger->Send("com.musicflow.app/window-visible", data.data(),
                           data.size());
}

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
  g_window_messenger = flutter_controller_->engine()->messenger();

  // 桌面歌词浮窗按钮事件(上一首/播放暂停/下一首/模式/喜欢/音量)经
  // tray 字符串通道回传 Dart,与托盘按钮共用同一条处理链路。
  // 「点击歌词栏空白处开关主窗口」不走 Dart:直接原生切换显隐
  // (开→收进托盘并通知 Flutter 冻结渲染;收→恢复前台并解除冻结)。
  // 注意必须用顶层窗口句柄(GetHandle),不能用 Flutter 子视图句柄:
  // view()->GetNativeWindow() 是 SetChildContent 挂进去的子 HWND,对它
  // SW_HIDE 只会藏掉内容、顶层窗体留在屏幕上,表现为「主窗口假死卡住」。
  g_main_window = GetHandle();
  DesktopLyricSetEventCallback([](const char* msg) {
    if (!g_window_messenger || msg == nullptr) return;
    if (std::string(msg) == "toggle_main_window") {
      if (g_main_window) {
        if (IsWindowVisible(g_main_window) && !IsIconic(g_main_window)) {
          ShowWindow(g_main_window, SW_HIDE);
          NotifyWindowVisible(false);
        } else {
          // 最小化过的先还原,普通隐藏的直接显示(SW_RESTORE 会把
          // 最大化窗口错误还原成普通尺寸)。
          ShowWindow(g_main_window,
                     IsIconic(g_main_window) ? SW_RESTORE : SW_SHOW);
          NotifyWindowVisible(true);
          SetForegroundWindow(g_main_window);
        }
      }
      return;
    }
    const std::string s(msg);
    std::vector<uint8_t> data(s.begin(), s.end());
    g_window_messenger->Send("com.musicflow.app/tray", data.data(),
                             data.size());
  });

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

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  g_window_messenger = nullptr;
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
    // 最小化到任务栏：窗口从屏幕消失，通知 Flutter 冻结渲染省 GPU。
    NotifyWindowVisible(false);
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
  if (method == "update_desktop_lyric_state") {
    // 桌面歌词浮窗:推送完整显示状态(歌名/歌手/歌词行/播放/喜欢/模式/音量)。
    DesktopLyricState st;
    if (const flutter::EncodableValue* arguments = call.arguments()) {
      if (std::holds_alternative<flutter::EncodableMap>(*arguments)) {
        const auto& m = std::get<flutter::EncodableMap>(*arguments);
        auto getStr = [&](const char* key) -> std::string {
          const auto it = m.find(flutter::EncodableValue(key));
          if (it != m.end()) {
            if (const auto* s = std::get_if<std::string>(&it->second)) {
              return *s;
            }
          }
          return "";
        };
        auto getBool = [&](const char* key, bool def) -> bool {
          const auto it = m.find(flutter::EncodableValue(key));
          if (it != m.end()) {
            if (const auto* b = std::get_if<bool>(&it->second)) return *b;
          }
          return def;
        };
        auto getDouble = [&](const char* key, double def) -> double {
          const auto it = m.find(flutter::EncodableValue(key));
          if (it != m.end()) {
            if (const auto* d = std::get_if<double>(&it->second)) return *d;
            if (const auto* i = std::get_if<int32_t>(&it->second)) {
              return static_cast<double>(*i);
            }
          }
          return def;
        };
        auto getInt = [&](const char* key, int32_t def) -> int32_t {
          const auto it = m.find(flutter::EncodableValue(key));
          if (it != m.end()) {
            if (const auto* i = std::get_if<int32_t>(&it->second)) return *i;
          }
          return def;
        };
        st.song = Utf8ToUtf16(getStr("song"));
        st.artist = Utf8ToUtf16(getStr("artist"));
        st.lyric = Utf8ToUtf16(getStr("lyric"));
        st.playing = getBool("playing", false);
        st.liked = getBool("liked", false);
        const std::string mode = getStr("mode");
        // 0=shuffle 1=repeatAll 2=repeatOne 3=order(顺序播放,remix 有序列表图形)。
        st.mode = mode == "shuffle"
                      ? 0
                      : (mode == "repeatOne" ? 2 : (mode == "order" ? 3 : 1));
        st.volume = getDouble("volume", 0.8);
        // 歌词填充色 0xRRGGBB,随 MINI 播放器歌词栏 accent;缺省保持默认粉。
        const int32_t colorRaw = getInt("lyricColor", -1);
        if (colorRaw >= 0) {
          st.lyricColor = RGB((colorRaw >> 16) & 0xFF, (colorRaw >> 8) & 0xFF,
                              colorRaw & 0xFF);
        }
      }
    }
    DesktopLyricUpdateState(st);
    result->Success();
    return;
  }
  if (method == "update_desktop_lyric_queue") {
    // 桌面歌词「播放队列」弹窗数据:已组好显示文本的队列行 + 当前曲下标。
    DesktopLyricQueue q;
    if (const flutter::EncodableValue* arguments = call.arguments()) {
      if (std::holds_alternative<flutter::EncodableMap>(*arguments)) {
        const auto& m = std::get<flutter::EncodableMap>(*arguments);
        const auto itemsIt = m.find(flutter::EncodableValue("items"));
        if (itemsIt != m.end()) {
          if (const auto* items =
                  std::get_if<flutter::EncodableList>(&itemsIt->second)) {
            for (const auto& item : *items) {
              if (const auto* s = std::get_if<std::string>(&item)) {
                q.items.push_back(Utf8ToUtf16(*s));
              }
            }
          }
        }
        const auto idxIt = m.find(flutter::EncodableValue("index"));
        if (idxIt != m.end()) {
          if (const auto* i = std::get_if<int32_t>(&idxIt->second)) {
            q.index = *i;
          }
        }
      }
    }
    DesktopLyricUpdateQueue(q);
    result->Success();
    return;
  }
  if (method == "update_desktop_lyric_switch_list") {
    // 桌面歌词「切换播放器」弹窗数据:设备行(名称/状态副标题/是否当前目标)。
    // 原生层只画两行文字并回传行号,切换动作由 Flutter 执行。
    DesktopLyricSwitchList list;
    if (const flutter::EncodableValue* arguments = call.arguments()) {
      if (std::holds_alternative<flutter::EncodableMap>(*arguments)) {
        const auto& m = std::get<flutter::EncodableMap>(*arguments);
        const auto loadingIt = m.find(flutter::EncodableValue("loading"));
        if (loadingIt != m.end()) {
          if (const auto* b = std::get_if<bool>(&loadingIt->second)) {
            list.loading = *b;
          }
        }
        const auto itemsIt = m.find(flutter::EncodableValue("items"));
        if (itemsIt != m.end()) {
          if (const auto* items =
                  std::get_if<flutter::EncodableList>(&itemsIt->second)) {
            for (const auto& item : *items) {
              const auto* row = std::get_if<flutter::EncodableMap>(&item);
              if (row == nullptr) continue;
              DesktopLyricSwitchItem it;
              const auto titleIt = row->find(flutter::EncodableValue("title"));
              if (titleIt != row->end()) {
                if (const auto* s = std::get_if<std::string>(&titleIt->second)) {
                  it.title = Utf8ToUtf16(*s);
                }
              }
              const auto subIt = row->find(flutter::EncodableValue("subtitle"));
              if (subIt != row->end()) {
                if (const auto* s = std::get_if<std::string>(&subIt->second)) {
                  it.subtitle = Utf8ToUtf16(*s);
                }
              }
              const auto curIt = row->find(flutter::EncodableValue("current"));
              if (curIt != row->end()) {
                if (const auto* b = std::get_if<bool>(&curIt->second)) {
                  it.current = *b;
                }
              }
              // 设备类型小徽章(DLNA/群组…):空则原生不画。
              const auto badgeIt = row->find(flutter::EncodableValue("badge"));
              if (badgeIt != row->end()) {
                if (const auto* s = std::get_if<std::string>(&badgeIt->second)) {
                  it.badge = Utf8ToUtf16(*s);
                }
              }
              // 接续箭头可用性:↓ 有现场可接回本机 / ↑ 有现场可推过去。
              const auto pullIt = row->find(flutter::EncodableValue("canPull"));
              if (pullIt != row->end()) {
                if (const auto* b = std::get_if<bool>(&pullIt->second)) {
                  it.canPull = *b;
                }
              }
              const auto pushIt = row->find(flutter::EncodableValue("canPush"));
              if (pushIt != row->end()) {
                if (const auto* b = std::get_if<bool>(&pushIt->second)) {
                  it.canPush = *b;
                }
              }
              // handoff:这一行**画不画**两支接续箭头(只有远端设备行为 true)。
              // 与 canPull/canPush 分开:后者只决定亮不亮,两支都不可用时也要
              // 画出来(置灰),否则用户会以为歌词窗少了功能(2026-09-10)。
              const auto hIt = row->find(flutter::EncodableValue("handoff"));
              if (hIt != row->end()) {
                if (const auto* b = std::get_if<bool>(&hIt->second)) {
                  it.handoff = *b;
                }
              }
              // isRefresh:「刷新设备列表」行(对齐 MINI 弹窗底部 refresh
              // 按钮)。点击只回传 switch_pick:N,由 Dart 重拉列表。
              const auto refreshIt =
                  row->find(flutter::EncodableValue("isRefresh"));
              if (refreshIt != row->end()) {
                if (const auto* b = std::get_if<bool>(&refreshIt->second)) {
                  it.isRefresh = *b;
                }
              }
              // icon:行首图标(1=耳机 2=基站 3=人群 4=刷新;0=小圆点兜底)。
              const auto iconIt = row->find(flutter::EncodableValue("icon"));
              if (iconIt != row->end()) {
                if (const auto* n = std::get_if<int32_t>(&iconIt->second)) {
                  it.icon = *n;
                }
              }
              list.items.push_back(std::move(it));
            }
          }
        }
      }
    }
    DesktopLyricUpdateSwitchList(list);
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
  if (method == "quit") {
    // Flutter 端已完成退出前保存(播放进度/音量落盘),这里真正结束进程:
    // 清理托盘图标 → 销毁主窗口 → 结束消息循环。SetQuitOnClose(false) 时
    // WM_DESTROY 不会自动 PostQuitMessage,必须手动结束。
    TrayShutdown();
    DestroyWindow(hwnd);
    PostQuitMessage(0);
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
      // 关闭按钮/WM_CLOSE：隐藏到托盘但进程继续后台播放。窗口已从屏幕消失，
      // 必须通知 Flutter 冻结渲染（停 Ticker + 冻结数据驱动），否则后台仍占 GPU。
      NotifyWindowVisible(false);
      return 0;

    case WM_SYSCOMMAND:
      // 拦截「最小化」：让窗口缩到系统托盘(SW_HIDE)，而不是停在任务栏。
      // 否则点最小化按钮只是普通任务栏最小化，与托盘「缩小状态」割裂，
      // 用户感知为「托盘缩小完全无法使用」。
      if ((wparam & 0xFFF0) == SC_MINIMIZE) {
        ShowWindow(hwnd, SW_HIDE);
        NotifyWindowVisible(false);
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
        // 退出也先经 Dart:Flutter 完成退出前保存后回调 native quit。
        case TRAY_QUIT: method = "quit"; break;
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
