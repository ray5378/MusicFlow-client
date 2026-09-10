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
//   6. 切换播放器按钮必须「紧挨音量右侧」(kOffSwitch < kOffVolume),
//      且点击只在自己的弹窗里 toggle —— 用户 2026-09-10 明确要求
//      「基站图标放在音量的右边」+「弹窗在桌面歌词上面新增,不回到主窗口」,
//      回归成回到主窗口弹窗或按钮跑回音量左边都会被这条拦下。
//
// 用法:dart run tool/desktop_lyric_guard.dart [仓库根,默认 .]
// 退出码:0 = 通过;1 = 存在回归(CI 拦截)。
import 'dart:io';

const String kNativeToggleFile = 'windows/runner/flutter_window.cpp';
const String kNativeLyricFile = 'windows/runner/desktop_lyric.cpp';
const String kNativeLogicHeader = 'windows/runner/desktop_lyric_logic.h';
const String kDartPushFile =
    'lib/providers/media/status_lyrics_provider.dart';
const String kDartScaffoldFile = 'lib/widgets/main_scaffold.dart';
const String kDartPopupFile = 'lib/providers/media/desktop_lyric_popup.dart';
const String kDartPeerFile = 'lib/data/models/peer.dart';
const String kDartTitleBarFile = 'lib/widgets/windows_title_bar.dart';
const String kDartAppFile = 'lib/app.dart';

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

  // ---- 6. 切换播放器按钮位置 + 弹窗归属 ----
  if (lyricSrc.isNotEmpty) {
    // 6a. 基站图标必须在音量右边:kOffSwitch 的偏移要小于 kOffVolume
    // (偏移是从右缘向左量的,越小越靠右)。
    final offSwitch = _constInt(lyricSrc, 'kOffSwitch');
    final offVolume = _constInt(lyricSrc, 'kOffVolume');
    if (offSwitch == null || offVolume == null) {
      errors.add('$kNativeLyricFile: 找不到 kOffSwitch/kOffVolume 常量');
    } else if (offSwitch >= offVolume) {
      errors.add(
        '$kNativeLyricFile: 切换播放器按钮不在音量右侧'
        '(kOffSwitch=$offSwitch 必须 < kOffVolume=$offVolume;'
        '偏移自右缘向左量,越小越靠右)',
      );
    }
    // 6b. 切歌按钮的点击分支必须 toggle 自己的 Switch 弹窗,且不得再
    // 直接发旧的 "switch_player"(那是「回主窗口弹窗」的旧协议)。
    //
    // 注意:kBtnIdxSwitch 在文件里出现三次(几何映射 / 图标绘制 / 点击派发),
    // 只有【点击派发】那处才是本次要检查的分支 —— 从 HitTestButton 之后
    // 的 switch(btn) 起找,避免误把 DrawButton 的 case 当点击处理。
    final clickSwitch = lyricSrc.indexOf('switch (btn)');
    final body = clickSwitch < 0
        ? null
        : _switchCaseBody(lyricSrc.substring(clickSwitch), 'kBtnIdxSwitch');
    if (body == null) {
      errors.add('$kNativeLyricFile: 找不到点击派发里的 switch(kBtnIdxSwitch)');
    } else {
      if (!body.contains('PopupKind::Switch')) {
        errors.add(
          '$kNativeLyricFile: 切换播放器按钮未展开自带弹窗'
          '(必须 SetPopup(PopupKind::Switch) —— 弹窗要长在歌词窗上方,'
          '不是回到主窗口弹)',
        );
      }
      if (body.contains('"switch_player"')) {
        errors.add(
          '$kNativeLyricFile: 切换播放器按钮仍在发旧的 switch_player'
          '(回归成「回主窗口弹窗」;应发 switch_player_open)',
        );
      }
      if (!body.contains('switch_player_open')) {
        errors.add(
          '$kNativeLyricFile: 切换播放器按钮未发 switch_player_open'
          '(原生层需要用它在展开时向 Flutter 要设备列表)',
        );
      }
    }
    // 6c. Dart 侧必须提供设备列表拉取入口(原生层展开弹窗时向它要数据),
    // 且主壳不得再把 switch_player 当成「打开主窗口弹窗」的信号。
    if (pushSrc.isNotEmpty && !pushSrc.contains('requestSwitchList')) {
      errors.add(
        '$kDartPushFile: 缺少 requestSwitchList(设备列表无人拉取推送)',
      );
    }
    final scaffold = read(kDartScaffoldFile);
    if (scaffold.isNotEmpty) {
      if (!scaffold.contains('switch_player_open')) {
        errors.add(
          '$kDartScaffoldFile: 未处理 switch_player_open'
          '(歌词窗设备弹窗拿不到设备列表)',
        );
      }
      if (!scaffold.contains('switch_pick:')) {
        errors.add(
          '$kDartScaffoldFile: 未处理 switch_pick:'
          '(点选设备行不会执行切换)',
        );
      }
    }
    // 6d. 设备行组拼必须走带单测的纯函数(顺序/当前项高亮有契约)。
    final popupSrc = read(kDartPopupFile);
    if (popupSrc.isNotEmpty &&
        !popupSrc.contains('composeDesktopLyricSwitchList')) {
      errors.add(
        '$kDartPopupFile: 缺少 composeDesktopLyricSwitchList'
        '(设备行顺序与当前项高亮必须由纯函数锁定)',
      );
    }
  }

  // ---- 7. WindowsWindowChrome 挂在 Overlay 之外,必须自带 Overlay ----
  //
  // 2026-09-10 真实事故:chrome 为「弹窗打开时顶部仍可拖拽」被挂进
  // MaterialApp.builder 的 Stack(见 app.dart),位置在 Navigator/Overlay
  // **之外**;而窗口控制按钮用了 Tooltip,显示时要 Overlay.of(context)
  // → 抛 "No Overlay widget found." → ErrorWidget 顶替 → 用户看到主窗口
  // 右上一列竖排黄字。修法是 chrome 自带一个 Overlay。
  // 这条规则锁死:①app.dart 仍然把 chrome 放在 builder 层(不能挪回
  // MainScaffold,否则弹窗顶部又拖不动);②chrome 内部必须自带 Overlay。
  {
    final appSrc = read(kDartAppFile);
    if (appSrc.isNotEmpty &&
        !appSrc.contains('WindowsWindowChrome()')) {
      errors.add(
        '$kDartAppFile: 未在 MaterialApp.builder 层挂 WindowsWindowChrome'
        '(挪回页面内会让弹窗打开时顶部无法拖动窗口)',
      );
    }
    final titleBarSrc = read(kDartTitleBarFile);
    if (titleBarSrc.isNotEmpty) {
      // 必须在 WindowsWindowChrome 内部出现 Overlay(自带祖先给 Tooltip 用)。
      final chromeIdx = titleBarSrc.indexOf('class WindowsWindowChrome');
      if (chromeIdx < 0) {
        errors.add('$kDartTitleBarFile: 找不到 WindowsWindowChrome 类定义');
      } else {
        final body = titleBarSrc.substring(chromeIdx);
        // 必须真的 `return Overlay(` 或 `= Overlay(` —— 只匹配注释里的
        // "Overlay(" 会被注释骗过(v4.3.42 期间实战踩到,已加此约束)。
        final realOverlay = RegExp(r'(?:return|=)\s*Overlay\(').hasMatch(body);
        if (!realOverlay) {
          errors.add(
            '$kDartTitleBarFile: WindowsWindowChrome 未自带 Overlay —— '
            '它挂在 Navigator/Overlay 之外,内部 Tooltip 会抛 '
            '"No Overlay widget found." 并画出黄字 ErrorWidget',
          );
        }
        // 反例保护:不要为了躲开 Overlay 而把 Tooltip 删掉(功能回归)。
        if (!body.contains('Tooltip(')) {
          errors.add(
            '$kDartTitleBarFile: 窗口控制按钮的 Tooltip 被移除 —— '
            '应当保留功能、用自带 Overlay 解决祖先缺失',
          );
        }
      }
    }
  }

  // ---- 8. 设备行的「徽章 + 接续箭头」三件套不许再退化 ----
  //
  // 2026-09-10 用户反馈「桌面歌词少了 DLNA 设备里面的部分功能」:歌词窗的
  // 设备行只画了设备名,缺了 MINI 播放条小弹窗 PeerCastRow 的 DLNA 徽章
  // 与 ↓/↑ 接续箭头。这条规则锁死整条链路(Dart 组拼 → 通道字段 → 原生
  // 绘制/命中 → 主壳分发),任何一环被删都会拦下。
  {
    final scaffoldSrc = read(kDartScaffoldFile);
    final popupSrc = read(kDartPopupFile);
    if (lyricSrc.isNotEmpty) {
      // 只认**代码里的字符串字面量**(带双引号),不认注释里的文字提及 ——
      // 上次规则 7 就被注释骗过一次(v4.3.42),这里直接用 C 字符串形态。
      for (final need in ['"switch_pull:%d"', '"switch_push:%d"']) {
        if (!lyricSrc.contains(need)) {
          errors.add(
            '$kNativeLyricFile: 缺少 $need 事件'
            '(设备行的 ↓/↑ 接续箭头点了没反应)',
          );
        }
      }
      for (final need in ['kArrowDownPts', 'kArrowUpPts']) {
        if (!lyricSrc.contains(need)) {
          errors.add(
            '$kNativeLyricFile: 缺少 $need 轮廓数据'
            '(接续箭头无字形可画;运行时加载字体在本机走不通)',
          );
        }
      }
      if (!lyricSrc.contains('HitTestSwitchHandoff')) {
        errors.add(
          '$kNativeLyricFile: 缺少 HitTestSwitchHandoff'
          '(接续箭头无法命中)',
        );
      }
      if (!lyricSrc.contains('item.badge')) {
        errors.add(
          '$kNativeLyricFile: 绘制设备行时未使用 badge'
          '(DLNA 徽章不会出现在歌词窗设备行)',
        );
      }
    }
    if (scaffoldSrc.isNotEmpty) {
      // 同上:要看到 `startsWith('switch_pull:')` 这样的真实分发代码,
      // 注释里提一句不算(v4.3.42 期间规则 7 就栽在这个坑上)。
      for (final need in [
        "startsWith('switch_pull:')",
        "startsWith('switch_push:')",
      ]) {
        if (!scaffoldSrc.contains(need)) {
          errors.add(
            '$kDartScaffoldFile: 未处理 $need'
            '(原生层发了接续事件但没人执行搬迁)',
          );
        }
      }
    }
    // 「正在播放」实时刷新闭环(2026-09-10):原生弹窗收起必须发
    // switch_close,Dart 侧必须据此停掉重拉循环 —— 漏了任何一端,要么
    // 弹窗关了还在每 5s 拉一遍(白耗),要么列表永远停在打开瞬间的快照。
    if (lyricSrc.isNotEmpty && !lyricSrc.contains('"switch_close"')) {
      errors.add(
        '$kNativeLyricFile: 缺少 "switch_close" 事件'
        '(设备弹窗收起时 Flutter 不知道,实时刷新循环停不下来)',
      );
    }
    if (scaffoldSrc.isNotEmpty && !scaffoldSrc.contains("case 'switch_close':")) {
      errors.add(
        '$kDartScaffoldFile: 未处理 switch_close 事件'
        '(设备弹窗收起后刷新循环不会停)',
      );
    }
    if (pushSrc.isNotEmpty && !pushSrc.contains('handoffSwitchRow')) {
      errors.add(
        '$kDartPushFile: 缺少 handoffSwitchRow'
        '(接续箭头的推/拉逻辑无人实现)',
      );
    }
    if (popupSrc.isNotEmpty) {
      for (final field in ['badge', 'canPull', 'canPush', 'handoff']) {
        if (!popupSrc.contains(field)) {
          errors.add(
            '$kDartPopupFile: DesktopLyricSwitchRow 缺少 $field 字段'
            '(歌词窗设备行拿不到徽章/接续可用性)',
          );
        }
      }
      // 「画不画箭头」必须是独立的 handoff 标志:用 canPull||canPush 兼作
      // 显示条件会让两支都不可用时整块箭头消失(2026-09-10 用户反馈
      // 「歌词窗比 MINI 少了功能」——MINI 的设备行是恒有两支、只置灰)。
      final rowIdx = popupSrc.indexOf('class DesktopLyricSwitchRow');
      final rowBody = rowIdx < 0 ? '' : popupSrc.substring(rowIdx);
      if (!RegExp(r'this\.handoff\s*=\s*false').hasMatch(rowBody)) {
        errors.add(
          '$kDartPopupFile: DesktopLyricSwitchRow.handoff 不存在或未默认 false'
          '(本机行会莫名长出接续箭头)',
        );
      }
    }
  }

  // ---- 规则 9:列表弹窗几何公式一致性(2026-09-10 裁行事故) ----
  // PopupLogicalHeight 的高度公式若漏算面板上下外边距 kListPopupMarginV,
  // 行区比可用高度多出 2*S(margin) → 最后一行永远被 break 裁掉(设备列表
  // 「只显示本机」的真实根因,队列弹窗同样中招)。公式、面板矩形必须共用
  // 同一常量,任何一边改回硬编码 S(6) 都在这里拦下。
  {
    final peerSrc = read(kDartPeerFile);
    if (lyricSrc.isNotEmpty) {
      if (!lyricSrc.contains('constexpr int kListPopupMarginV')) {
        errors.add(
          '$kNativeLyricFile: 缺少 kListPopupMarginV 常量'
          '(面板外边距与高度公式各自硬编码,迟早再次漂移裁行)',
        );
      }
      // 公式里必须出现两次(Queue 与 Switch 两个分支)。
      final formulaHits =
          'kListPopupMarginV * 2'.allMatches(lyricSrc).length;
      if (formulaHits < 2) {
        errors.add(
          '$kNativeLyricFile: PopupLogicalHeight 的 Queue/Switch 公式'
          '未同时加上 kListPopupMarginV * 2(只配了 $formulaHits 处,'
          '缺的那个弹窗最后一行会被裁掉)',
        );
      }
      // 面板矩形必须引用同一常量(不再允许 S(6) 硬编码)。
      if (!lyricSrc.contains('rc.top = S(kListPopupMarginV);') ||
          !lyricSrc.contains('rc.bottom = g_popupH - S(kListPopupMarginV);')) {
        errors.add(
          '$kNativeLyricFile: ListPanelRect/SwitchPanelRect 未使用 '
          'S(kListPopupMarginV) 作上下边距(与高度公式脱钩会再次裁行)',
        );
      }
      // 接续箭头顺序:↓(which=0)必须在左 —— 位移公式必须是 (1 - which)。
      if (!lyricSrc.contains('(1 - which)')) {
        errors.add(
          '$kNativeLyricFile: HandoffCx 未按 (1 - which) 定位'
          '(↓/↑ 左右顺序与 MINI 弹窗 PeerCastRow 颠倒)',
        );
      }
      // 行首图标:四个字形缺一不可(本机耳机/DLNA 基站/群组/刷新)。
      for (final glyph in [
        'kRemixHeadphone',
        'kRemixGroup',
        'kRemixRefresh',
        'kRemixSwitchPlayer',
      ]) {
        if (!lyricSrc.contains(glyph)) {
          errors.add(
            '$kNativeLyricFile: 缺少字形 $glyph'
            '(设备行图标不完整,与 MINI 弹窗 PeerCastRow 不对标)',
          );
        }
      }
      // 手写字形(接续箭头)必须放在生成区标记之外:
      // gen_lyric_glyphs.py --patch 会整体重写 START..END 之间的内容,
      // 混进去的手写数据会被静默清掉(v4.3.42 实际发生过)。
      final startMark = lyricSrc.indexOf(
          '// ---- 硬编码 remixicon 字形轮廓(由 tool/gen_lyric_glyphs.py 生成');
      final endMark = lyricSrc.indexOf('// ---- end glyph data ----');
      final arrowDef = lyricSrc.indexOf('static const RemixGlyphDef kArrowDown{');
      if (startMark < 0 || endMark < 0 || arrowDef < 0 ||
          arrowDef < endMark) {
        errors.add(
          '$kNativeLyricFile: kArrowDown 轮廓不在 glyph 生成区标记之后'
          '(下次 gen_lyric_glyphs.py --patch 会把它静默清掉)',
        );
      }
    }
    // Dart 侧「正在播放」实时刷新闭环:缓存 map + 5s 循环必须存在。
    if (pushSrc.isNotEmpty) {
      for (final need in [
        '_fetchSwitchNowPlaying',
        '_refreshSwitchAndPush',
        'stopSwitchAutoRefresh',
      ]) {
        if (!pushSrc.contains(need)) {
          errors.add(
            '$kDartPushFile: 缺少 $need'
            '(桌面歌词设备行的正在播放不会实时更新)',
          );
        }
      }
    }
    // 列表接口 queue.total 缺失时必须回落 items.length,否则列表来源的
    // queueTotal 恒为 0、↓ 箭头永远不亮(实测 GET /peers 无 total 字段)。
    if (peerSrc.isNotEmpty &&
        !peerSrc.contains("(j['queue']['items'] as List<dynamic>?)?.length")) {
      errors.add(
        '$kDartPeerFile: queueTotal 缺少 items.length 回落'
        '(列表接口没有 total 字段,↓ 箭头会永远置灰)',
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
    '捕获释放/取色去重 key/切换播放器按钮位置与弹窗归属 全部符合约定',
  );
}

/// 取 `constexpr int <name> = <数字>;` 的值,找不到返回 null。
int? _constInt(String src, String name) {
  final m = RegExp('constexpr\\s+int\\s+$name\\s*=\\s*(\\d+)').firstMatch(src);
  return m == null ? null : int.tryParse(m.group(1)!);
}

/// 取 `case <label>:` 到下一个 `case ` 之间的源码(用于检查分支实际行为)。
String? _switchCaseBody(String src, String label) {
  final start = src.indexOf('case $label:');
  if (start < 0) return null;
  final next = src.indexOf('case kBtnIdx', start + 1);
  return src.substring(start, next < 0 ? src.length : next);
}
