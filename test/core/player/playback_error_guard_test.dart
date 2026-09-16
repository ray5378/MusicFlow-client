// 守卫测试：本机播放「失败自动跳下一首」契约（2026-09-09 拍板）。
//
// 背景：本机链路的失败跳曲走 PlayerController._handlePlaybackError，而
// PlayerController 依赖 Riverpod + just_audio + API client，无法像纯逻辑那样
// 轻量实例化（现有 player 测试都是 ShuffleHistory / seek policy 这类纯函数）。
// 因此用**源码契约扫描**钉死决策，防止以下回归：
//   1. 播放失败后不跳（删掉 next() 或改成静默 return）→ 用户卡在坏歌上；
//   2. 重新引入「连续失败 N 次就停播」或死歌黑名单 → 长段坏源时中途停住、
//      以及把「服务端换源已救回」的歌永久误杀。
// 与 .github/workflows/playback-chain-guard.yml 的 grep 守卫互补：
// 那边扫全 lib/，这边精确到方法体与调用点。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

/// 截取方法体：从 `void _handlePlaybackError(` 起，到下一个顶格 `  }` 为止。
String _methodBody(String src, String signature) {
  final start = src.indexOf(signature);
  if (start < 0) return '';
  final end = src.indexOf('\n  }', start);
  return end < 0 ? src.substring(start) : src.substring(start, end);
}

void main() {
  const srcPath = 'lib/providers/player/player_provider.dart';
  final src = _read(srcPath);

  test('失败处理必须存在且自动跳下一首', () {
    const sig = 'void _handlePlaybackError(String? songId) {';
    final body = _methodBody(src, sig);
    expect(body, isNotEmpty, reason: '$srcPath 里找不到 $sig');
    // 契约一：必须推进到下一首。
    expect(body, contains('next()'),
        reason: '播放失败必须自动跳下一首（下一曲推进靠 next()）');
    // 契约二：不得有「停播」分支（isPlaying: false / stop / pause 都算）。
    expect(body.contains('isPlaying: false'), isFalse,
        reason: '无停播阈值：失败不得把播放器置为停止态');
  });

  test('next() 必须可达：不得被恒真短路变成死代码', () {
    // 2026-09-10 变异实测发现：把方法体改成 `if (true) return;` 后，
    // 上面「包含 next()」的字面断言**全部照过**，但播放器实际永远卡在坏源上。
    // 这正是「播放链路卡住」的典型形态，必须在结构上钉死。
    final body = _methodBody(src, 'void _handlePlaybackError(String? songId) {');
    for (final pattern in <RegExp>[
      RegExp(r'if\s*\(\s*true\s*\)'),
      RegExp(r'if\s*\(\s*1\s*==\s*1\s*\)'),
    ]) {
      expect(pattern.hasMatch(body), isFalse,
          reason: '方法体出现恒真短路（${pattern.pattern}）：next() 成为死代码，'
              '失败后不会跳曲，用户卡在坏源上');
    }
    // next() 之前的提前 return 只允许 mounted 守卫。
    final beforeNext = body.substring(0, body.indexOf('next()'));
    final guardReturns =
        RegExp(r'^\s*if\s*\([^)]*\)\s*\{?\s*return;', multiLine: true)
            .allMatches(beforeNext)
            .map((m) => m.group(0)!.trim());
    for (final g in guardReturns) {
      expect(g.contains('mounted'), isTrue,
          reason: 'next() 前出现非 mounted 的提前 return（$g）：跳曲被短路');
    }
  });

  test('失败处理里不得重新引入停播阈值或死歌黑名单', () {
    final body = _methodBody(src, 'void _handlePlaybackError(String? songId) {');
    for (final banned in <String>[
      '_failStreak',
      '_maxFailStreak',
      '_deadSongs',
      '_markSongDead',
    ]) {
      expect(body.contains(banned), isFalse,
          reason: '无停播阈值/死歌名单：$banned 不得出现在失败处理里');
    }
  });

  test('关键失败分支仍接在 _handlePlaybackError 上', () {
    // 定义 1 处 + 调用点若干。删掉调用点 = 失败后原地不动，必须拦住。
    final hits = RegExp(r'_handlePlaybackError\(').allMatches(src).length;
    expect(hits, greaterThanOrEqualTo(4),
        reason: '_handlePlaybackError 调用点过少($hits)，疑似有失败分支被改成静默返回');
  });

  test('整份 player_provider 无停播阈值/死歌名单残留', () {
    for (final banned in <String>[
      '_failStreak',
      '_maxFailStreak',
      '_deadSongs',
      '_markSongDead',
    ]) {
      expect(src.contains(banned), isFalse, reason: '契约回归：$banned 已整体移除');
    }
  });

  test('失败自动跳必须同步推进：不得冻结 next 阻断流转上报', () {
    // 2026-09-17 修正 v5.0.9 回归：把失败跳转改成 `Future.delayed(wait, next)`
    // 会在坏源/切歌时让播放器停在失败态（isPlaying=false、currentSong 不推进），
    // 本机实时状态上报变「无在播歌」→ 流转播放页对端读不到歌曲/封面。
    // 因此契约改为：失败跳转**同步**调用 next()，禁止用延迟冻结它。
    final body = _methodBody(src, 'void _handlePlaybackError(String? songId) {');
    // 同方法体里不得出现延迟跳转（去延迟 = 回归实录），否则会在那段时间里
    // 把播放器冻结在失败态，破坏流转播放的实时上报。
    expect(body.contains('Future.delayed'), isFalse,
        reason: '失败自动跳不得用 Future.delayed 冻结 next()：坏源时段会停在失败态，'
            '流转播放页读不到歌曲与封面（v5.0.9 回归）');
    // 排除「延迟 + 提前 return」形态：wait 分支 return 会让 next() 变成可被延后。
    expect(RegExp(r'wait\s*[<>]=\s*\w+').hasMatch(body), isFalse,
        reason: '不得用 wait 类分支提前 return 延后 next()');
  });
}
