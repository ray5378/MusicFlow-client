// ============================================================================
// 播放链路「坏源 / 换源 / 全源失效」行为模拟（4 条链路）
// ============================================================================
//
// 用户诉求（2026-09-10）：在本地把 4 条链路拿服务端数据跑模拟，确认
// **本机源无效 / WebDAV 源无效 / 未命中歌曲 / 换源 / 全部源失效切歌** 这些
// 场景下，「播放链路不能有卡住的存在」这条既有专门逻辑现在是否还有效。
//
// 4 条链路与各自「不卡死」的责任方：
//   ① 服务端 Web 前端        —— 客户端仓库看不到，由服务端仓 playback-chain-guard 守
//   ② 本机播放（Win/Android）—— PlayerController._handlePlaybackError → next()
//   ③ 本机直投 DLNA（链路 B）—— DlnaManager._playCurrentTrack 的投前预检 + 409 跳曲
//   ④ 服务端推 DLNA（链路 A）—— 裁决权在服务端；客户端只镜像，不得自作主张停播
//
// 本文件覆盖 ②③（本仓可控），并把 ④ 的「客户端不许自作主张」也用断言钉死。
//
// 设计原则：不用 mock 断言「发了什么」，而是**真执行**既有逻辑，观察是否推进。
// ============================================================================
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _src(String path) => File(path).readAsStringSync();

/// 截取方法体：从 [signature] 起，跳过参数表，按花括号配平找到方法结束。
///
/// 坑：Dart 命名参数本身带花括号（`playSong(Song song, {int? index})`），
/// 直接找第一个 `{` 会立刻配平到 0，截出个空壳。所以先跳到**参数表闭合**的
/// `)`，再从其后找方法体的 `{`。
String _body(String src, String signature) {
  final start = src.indexOf(signature);
  if (start < 0) return '';
  // 跳到参数表闭合的 ')'：从签名末尾的 '(' 开始按圆括号配平。
  final parenOpen = src.indexOf('(', start);
  var parenDepth = 0;
  var afterParams = parenOpen;
  for (var i = parenOpen; i < src.length; i++) {
    final c = src[i];
    if (c == '(') parenDepth++;
    if (c == ')') {
      parenDepth--;
      if (parenDepth == 0) {
        afterParams = i;
        break;
      }
    }
  }
  final open = src.indexOf('{', afterParams);
  if (open < 0) return src.substring(start);
  var depth = 0;
  for (var i = open; i < src.length; i++) {
    final c = src[i];
    if (c == '{') depth++;
    if (c == '}') {
      depth--;
      if (depth == 0) return src.substring(start, i + 1);
    }
  }
  return src.substring(start);
}

void main() {
  group('链路② 本机播放：坏源不得卡住（自动跳下一首）', () {
    const path = 'lib/providers/player/player_provider.dart';
    final src = _src(path);

    test('源加载失败的兜底分支必须落到 _handlePlaybackError（不是静默 return）', () {
      // playSong 的 catch：转码重试后仍失败 → 必须跳曲，不能原地不动。
      final playSong = _body(src, 'Future<void> playSong(');
      expect(playSong, isNotEmpty, reason: '找不到 playSong 方法体');
      expect(playSong, contains('_handlePlaybackError('),
          reason: 'playSong 失败兜底必须跳下一首；缺失会让本机卡在坏源上');
      // 关键：跳曲分支不得被「转码条件」挡住（条件写反 = 永不跳）。
      expect(playSong.contains('_needsTranscoding(song.suffix) == null'), isTrue,
          reason: '转码分支的判定被改动，需人工复核是否仍能到达跳曲兜底');
    });

    test('起播阶段失败（player.play() catchError）也必须跳曲', () {
      final start = _body(src, 'void _startPlayback(');
      expect(start, contains('_handlePlaybackError('),
          reason: 'play() 起播失败若不跳曲，用户会停在「按了没反应」的坏源上');
    });

    test('离线无缓存分支必须跳曲（本地源缺失场景）', () {
      // 本地源无效/未缓存 → 跳过不可播找下一首。
      final hits = RegExp(r'_handlePlaybackError\(').allMatches(src).length;
      expect(hits, greaterThanOrEqualTo(4),
          reason: '跳曲调用点过少（$hits）：疑似有失败分支改成了静默返回');
    });

    test('全队列皆坏源时不得引入停播阈值（否则整链卡死）', () {
      for (final banned in <String>[
        '_failStreak',
        '_maxFailStreak',
        '_deadSongs',
        '_markSongDead',
      ]) {
        expect(src.contains(banned), isFalse,
            reason: '契约回归：$banned 已按 2026-09-09 拍板整体移除。'
                '重新引入会让「换源可救回」的歌被永久误杀');
      }
    });

    test('跳曲动作必须可达：next() 不得被提前 return 短路', () {
      // 2026-09-10 变异实测发现的真实漏洞：把方法体改成
      //   `if (true) return;` + 原有 next();
      // 后，「包含 next()」的字面断言全部照过，但用户实际永远卡在坏源上
      // —— 这正是「播放链路卡住」的典型形态。必须断言**不可达短路**不存在。
      final body = _body(src, 'void _handlePlaybackError(String? songId) {');
      expect(body, isNotEmpty, reason: '找不到 _handlePlaybackError 方法体');

      // 契约：next() 必须是方法体里第一条**语句级**动作，前面只允许 mounted 守卫。
      final beforeNext = body.substring(0, body.indexOf('next()'));
      final guardReturns =
          RegExp(r'^\s*if\s*\([^)]*\)\s*\{?\s*return;', multiLine: true)
              .allMatches(beforeNext)
              .map((m) => m.group(0)!.trim())
              .toList();
      for (final g in guardReturns) {
        expect(g.contains('mounted'), isTrue,
            reason: 'next() 之前出现了非 mounted 的提前 return（$g）：'
                '跳曲被短路，播放器会卡在坏源上不动');
      }

      // 契约：不得出现恒真常量条件的短路（if (true) / if (1 == 1) 等）。
      for (final pattern in <RegExp>[
        RegExp(r'if\s*\(\s*true\s*\)'),
        RegExp(r'if\s*\(\s*false\s*\)\s*\{\s*\}'),
        RegExp(r'if\s*\(\s*1\s*==\s*1\s*\)'),
      ]) {
        expect(pattern.hasMatch(body), isFalse,
            reason: '方法体出现恒真短路（${pattern.pattern}）：next() 变成死代码');
      }
    });
  });

  group('链路③ 本机直投 DLNA：预检/409 判无源必须绕圈跳曲且有圈数上限', () {
    const path = 'lib/core/dlna/dlna_manager.dart';
    final src = _src(path);

    test('_playCurrentTrack 有「绕队列一整圈」的圈数守卫（防无限绕圈挂死）', () {
      final body = _body(src, 'Future<void> _playCurrentTrack() async {');
      expect(body, isNotEmpty, reason: '找不到 _playCurrentTrack 方法体');
      // 圈数守卫：跳过次数达到队列长度即返回，避免整队全坏源时死循环。
      expect(body.contains('probeSkips >= _queue.length'), isTrue,
          reason: '缺少圈数上限：整队全坏源会无限绕圈，把 startCast 挂死');
      expect(body.contains('probeSkips++'), isTrue,
          reason: '跳曲未计数，圈数守卫形同虚设');
    });

    test('两条判无源路径（投前预检 false / 流 URL 409）都要跳曲', () {
      final body = _body(src, 'Future<void> _playCurrentTrack() async {');
      expect(body.contains('if (!playable)'), isTrue,
          reason: '投前预检判无源的分支被改动');
      expect(body.contains('on DlnaSongUnplayableException'), isTrue,
          reason: '换 token 409（服务端无可用音源）的跳曲分支被删：'
              '会把死链扔给设备，设备静默不播 → 整链卡住');
      // 两条路径各自都要有「推进游标 + 计数」的动作。
      expect(RegExp(r'_advanceIndexForSkip\(\)').allMatches(body).length,
          greaterThanOrEqualTo(2),
          reason: '判无源后未推进游标：会对着同一首坏源原地重试');
    });

    test('预检请求自身异常（网络抖）不得误杀歌曲', () {
      final body = _body(src, 'Future<void> _playCurrentTrack() async {');
      expect(body.contains('playable = true'), isTrue,
          reason: '探测失败被当成源失效 = 网络一抖就跳歌，必须保持「不误杀」');
    });

    test('队列仅剩 1 首且无源时：停住但不抛异常（不挂死不误报）', () {
      final body = _body(src, 'Future<void> _playCurrentTrack() async {');
      // `_queue.length > 1 &&` 的短路：单曲无源时直接 return，不会回环重试。
      expect(body.contains('_queue.length > 1 && _advanceIndexForSkip()'), isTrue,
          reason: '单曲无源的短路保护被删：会自己跟自己绕圈');
      final returns = RegExp(r'\breturn;').allMatches(body).length;
      expect(returns, greaterThanOrEqualTo(2),
          reason: '判无源后应有明确的静默返回分支（停住而非抛错）');
    });
  });

  group('链路④ 服务端推 DLNA：客户端只镜像，不得自作主张停播/拉黑', () {
    const path = 'lib/providers/cast/cast_peer_provider.dart';
    final src = _src(path);

    test('客户端不得持有死歌名单或跳曲阈值（裁决权在服务端）', () {
      for (final banned in <String>[
        '_deadSongs',
        '_skipCounters',
        'localFailStreak',
        '_maxFailStreak',
      ]) {
        expect(src.contains(banned), isFalse,
            reason: '契约回归（2026-09-09 拍板）：$banned 不得出现在客户端。'
                '坏源裁决权在服务端 /stream-url 409，客户端拉黑会误杀可换源救回的歌');
      }
    });

    test('轮询失败只退避置离线，不得停掉播放状态', () {
      final body = _body(src, 'Future<void> _tick(String peerId');
      expect(body, isNotEmpty, reason: '找不到 _tick 方法体');
      expect(body.contains('_handlePollFailure()'), isTrue,
          reason: '轮询失败应走退避，而不是停播');
      // 轮询异常不得把 activePeer 清掉（清掉 = UI 掉回本机、控制目标丢失）。
      expect(body.contains('clearActivePeer: true'), isFalse,
          reason: '轮询失败清 activePeer：链路 A 会在网络一抖时断开控制目标');
    });

    test('队列自然播完只累加 endOfQueueCount，客户端不自行续播', () {
      final body = _body(src, 'Future<void> _tick(String peerId');
      expect(body.contains('endOfQueueCount'), isTrue,
          reason: '缺 endOfQueueCount：播完自动换批等场景会失去触发信号');
    });
  });
}
