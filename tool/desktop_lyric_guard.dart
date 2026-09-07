// 桌面歌词浮窗结构守卫(CI 防线之一,desktop-lyric-guard.yml 调用)。
//
// 桌面歌词是原生 Win32 C++ + Dart 推送链路的组合,编译期抓不住的跨端
// 约定全靠结构扫描锁死。每条规则都对应一次真实事故,防止回归:
//   1. 主窗口句柄必须是顶层 GetHandle() —— v4.3.20 前 toggle 用了
//      Flutter 子视图句柄,隐藏只藏内容、顶层留屏,表现为「主窗口假死」;
//   2. 恢复分支必须按 IsIconic 区分 SW_RESTORE/SW_SHOW —— SW_RESTORE
//      会把最大化窗口错误还原成普通尺寸;
//   3. 渲染必须走 UpdateLayeredWindow 逐像素 alpha,禁止 LWA_ALPHA /
//      SetWindowRgn 回归旧的「整窗 210 透明度 + 区域裁剪」管线;
//   4. WM_LBUTTONUP 处理块必须出现 ReleaseCapture —— 捕获泄漏会让
//      鼠标输入被歌词窗吃光,主窗口表现为「点不动」;
//   5. Dart 推送去重 key 必须包含 lyricColor —— 丢掉会导致歌词颜色
//      跟随 MINI 播放器失效(封面配色变了浮窗不刷新)。
//
// 用法:dart run tool/desktop_lyric_guard.dart [仓库根,默认 .]
// 退出码:0 = 通过;1 = 存在回归(CI 拦截)。
import 'dart:io';

const String kNativeToggleFile = 'windows/runner/flutter_window.cpp';
const String kNativeLyricFile = 'windows/runner/desktop_lyric.cpp';
const String kNativeLogicHeader = 'windows/runner/desktop_lyric_logic.h';
const String kDartPushFile =
    'lib/providers/media/status_lyrics_provider.dart';

void main(List<String> args) {
  final root = args.isNotEmpty ? args.first : '.';
  final errors = <String>[];

  String read(String relPath) {
    final file = File('$root/$relPath'.replaceAll('\\', '/'));
    if (!file.existsSync()) {
      errors.add('$relPath: 文件不存在(被移动/重命名?)');
      return '';
    }
    return file.readAsStringSync();
  }

  // ---- 1/2. 主窗口开关路径(flutter_window.cpp) ----
  final toggleSrc = read(kNativeToggleFile);
  if (toggleSrc.isNotEmpty) {
    if (!toggleSrc.contains('g_main_window = GetHandle();')) {
      errors.add(
        '$kNativeToggleFile: g_main_window 未用顶层 GetHandle() 初始化'
        '(对 Flutter 子视图 SW_HIDE 会藏内容留空壳,主窗口假死)',
      );
    }
    if (toggleSrc.contains(
      'g_main_window = flutter_controller_->view()->GetNativeWindow()',
    )) {
      errors.add(
        '$kNativeToggleFile: g_main_window 禁止指向 Flutter 子视图'
        '(v4.3.20 前的主窗口假死根因)',
      );
    }
    if (!toggleSrc.contains('IsIconic(g_main_window) ? SW_RESTORE : SW_SHOW')) {
      errors.add(
        '$kNativeToggleFile: 恢复分支缺少 IsIconic 区分'
        '(SW_RESTORE 会把最大化主窗口错误还原)',
      );
    }
  }

  // ---- 3/4. 歌词窗渲染与鼠标捕获(desktop_lyric.cpp) ----
  final lyricSrc = read(kNativeLyricFile);
  if (lyricSrc.isNotEmpty) {
    if (!lyricSrc.contains('UpdateLayeredWindow')) {
      errors.add(
        '$kNativeLyricFile: 未使用 UpdateLayeredWindow 逐像素 alpha 管线',
      );
    }
    // 只拦真实 API 调用:SetWindowRgn( 带括号、SetLayeredWindowAttributes
    // 是旧管线入口;注释里的文字提及不算。
    for (final banned in ['SetWindowRgn(', 'SetLayeredWindowAttributes']) {
      if (lyricSrc.contains(banned)) {
        errors.add(
          '$kNativeLyricFile: 出现 $banned(旧「整窗透明度+区域裁剪」'
          '管线回归,未悬停背景必须由 alpha=0 像素天然透明实现)',
        );
      }
    }
    final upStart = lyricSrc.indexOf('case WM_LBUTTONUP:');
    final upEnd = lyricSrc.indexOf('case WM_RBUTTONUP:');
    if (upStart < 0 || upEnd <= upStart) {
      errors.add('$kNativeLyricFile: 找不到 WM_LBUTTONUP 处理块');
    } else if (!lyricSrc
        .substring(upStart, upEnd)
        .contains('ReleaseCapture')) {
      errors.add(
        '$kNativeLyricFile: WM_LBUTTONUP 块内缺少 ReleaseCapture'
        '(捕获泄漏 → 鼠标被歌词窗独占,主窗口点不动)',
      );
    }
  }

  // ---- 纯逻辑头必须存在且被引用(单测覆盖的前提) ----
  read(kNativeLogicHeader);
  if (lyricSrc.isNotEmpty &&
      !lyricSrc.contains('#include "desktop_lyric_logic.h"')) {
    errors.add(
      '$kNativeLyricFile: 未引用 desktop_lyric_logic.h'
      '(描边色/跑马灯/阈值逻辑必须留在带单测的纯逻辑头中)',
    );
  }

  // ---- 5. Dart 推送去重 key 含颜色 ----
  final pushSrc = read(kDartPushFile);
  if (pushSrc.isNotEmpty) {
    final keyStart = pushSrc.indexOf("final key =");
    final keyEnd = pushSrc.indexOf('if (key ==');
    if (keyStart < 0 || keyEnd <= keyStart) {
      errors.add('$kDartPushFile: 找不到推送去重 key 构造');
    } else if (!pushSrc
        .substring(keyStart, keyEnd)
        .contains('lyricColor')) {
      errors.add(
        '$kDartPushFile: 去重 key 未包含 lyricColor'
        '(封面配色变化将不再触发浮窗歌词颜色刷新)',
      );
    }
  }

  if (errors.isNotEmpty) {
    stderr.writeln('桌面歌词守卫检查失败(${errors.length} 处):');
    for (final e in errors) {
      stderr.writeln('  - $e');
    }
    exit(1);
  }

  stdout.writeln(
    'OK: 桌面歌词守卫通过 —— 顶层句柄/恢复分支/逐像素alpha管线/'
    '捕获释放/取色去重 key 全部符合约定',
  );
}
