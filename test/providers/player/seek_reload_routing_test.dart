// 本机 seek 的重拉路由守卫(2026-09-23 真机事故回归)。
//
// 事故现场:Android 本机播放任意源的歌,点击/拖动进度条后**声音始终从头播放**,
// UI 进度却停在拖动的位置。240 侧日志证明服务端正常(同曲 timeOffset=183 的流
// 刚好短 183s、且从未收到无偏移的重拉请求);客户端 SEEKDBG 显示 seek 走的是裸
// `player.seek()`(`seek execute`),漂移兜底被 just_audio 的「立刻报回目标位置」
// 骗过(driftMs 稳定 200~230ms)→ 永远不升级重拉。
//
// 根因是分支只看 `_seekByReloadStream` 这个可变字段,而它会在若干路径上被清成
// false(起流后加载被作废提前 return、preview 起流写 false 等)。本文件把新的判定
// 契约钉死:**只要当前真实加载/上下文里的地址是本服务端的流,就必须重拉**,
// 无论那个字段是什么。
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/providers/player/transcoded_stream_seek.dart';

const String _songId = '267a07ce-27f4-4d9f-b9d8-3a41826345c2';
const String _otherSongId = 'ad64feb1-f69c-4f9e-9d17-c1a9237872f1';

/// 真机日志里的服务端流地址形状:签名三件套(u/t/s) + id + format/maxBitRate。
String _serverStreamUrl({
  String path = '/rest/stream',
  String? format = '-',
  String? maxBitRate = '-',
  String? timeOffset,
  String id = _songId,
}) {
  final params = <String, String>{
    'u': 'xyz5378',
    't': 'd41d8cd98f00b204e9800998ecf8427e',
    's': 'deadbeef',
    'v': '1.16.1',
    'c': 'MusicFlow',
    'id': id,
    if (format != null) 'format': format,
    if (maxBitRate != null) 'maxBitRate': maxBitRate,
    if (timeOffset != null) 'timeOffset': timeOffset,
  };
  return Uri.parse(
    'https://music.example.com:35378$path',
  ).replace(queryParameters: params).toString();
}

SeekReloadPlan? _plan({
  Duration target = const Duration(seconds: 231, milliseconds: 510),
  String? contextSongId = _songId,
  String? contextUrl,
  bool contextAllowsReload = true,
  String? loadedSourceUrl,
  bool serverPipelinedHttp = true,
}) {
  return resolveSeekReloadPlan(
    songId: _songId,
    target: target,
    contextSongId: contextSongId,
    contextUrl: contextUrl,
    contextAllowsReload: contextAllowsReload,
    loadedSourceUrl: loadedSourceUrl,
    serverPipelinedHttp: serverPipelinedHttp,
  );
}

String _timeOffsetOf(String url) =>
    Uri.parse(url).queryParameters['timeOffset'] ?? '';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('isServerStreamUrl', () {
    test('accepts this server stream and stream-remote URLs', () {
      expect(isServerStreamUrl(_serverStreamUrl()), isTrue);
      expect(
        isServerStreamUrl(_serverStreamUrl(path: '/rest/stream-remote')),
        isTrue,
      );
      expect(isServerStreamUrl(_serverStreamUrl(timeOffset: '90')), isTrue);
    });

    test('rejects external CDN links, files and unsigned URLs', () {
      expect(
        isServerStreamUrl('https://m701.music.126.net/20260923/abc.mp3'),
        isFalse,
      );
      expect(isServerStreamUrl('file:///data/cache/267a07ce.flac'), isFalse);
      // 少了签名三件套 → 不是本服务端的流,无法靠改写 URL 重拉。
      expect(
        isServerStreamUrl('https://music.example.com:35378/rest/stream?id=x'),
        isFalse,
      );
      expect(
        isServerStreamUrl(
          'https://music.example.com:35378/rest/ping?u=1&t=2&s=3',
        ),
        isFalse,
      );
      expect(isServerStreamUrl(null), isFalse);
      expect(isServerStreamUrl(''), isFalse);
    });
  });

  group('buildTimeOffsetStreamUrl', () {
    test('writes timeOffset and keeps every other parameter', () {
      final url = buildTimeOffsetStreamUrl(
        _serverStreamUrl(),
        const Duration(seconds: 231, milliseconds: 510),
      );
      expect(_timeOffsetOf(url), '231');
      final q = Uri.parse(url).queryParameters;
      expect(q['u'], 'xyz5378');
      expect(q['t'], 'd41d8cd98f00b204e9800998ecf8427e');
      expect(q['s'], 'deadbeef');
      expect(q['id'], _songId);
    });

    test('removes timeOffset when seeking back to the very beginning', () {
      final url = buildTimeOffsetStreamUrl(
        _serverStreamUrl(timeOffset: '183'),
        Duration.zero,
      );
      expect(_timeOffsetOf(url), '');
      expect(Uri.parse(url).queryParameters.containsKey('timeOffset'), isFalse);
    });
  });

  group('resolveSeekReloadPlan', () {
    test('keeps the existing context path when it is trustworthy', () {
      final plan = _plan(contextUrl: _serverStreamUrl());
      expect(plan, isNotNull);
      expect(plan!.origin, 'context');
      expect(_timeOffsetOf(plan.url), '231');
      expect(plan.format, isNull);
      expect(plan.maxBitRate, isNull);
    });

    test('recovers the reload address when the bookkeeping was lost', () {
      // ★ 事故回归:上下文被清空(_currentStreamUrl = null / 歌 id 丢失)而标记
      //   恰好为 false 时,旧实现直接掉进裸 player.seek() → 从头播。新实现改用
      //   播放器**当前真实加载**的地址判定,必须仍然重拉。
      final plan = _plan(
        contextSongId: null,
        contextUrl: null,
        loadedSourceUrl: _serverStreamUrl(),
      );
      expect(plan, isNotNull);
      expect(plan!.origin, 'context_lost');
      expect(_timeOffsetOf(plan.url), '231');
    });

    test('reloads a preview stream that is served by this server', () {
      // preview 起流原先硬编码 seekByReloadStream:false,而 /rest/stream-remote
      // 同样是实时管道流 → 拖动从头播。标记不可信时按地址事实重拉。
      final plan = _plan(
        contextUrl: _serverStreamUrl(path: '/rest/stream-remote'),
        contextAllowsReload: false,
      );
      expect(plan, isNotNull);
      expect(plan!.origin, 'context_plain');
      expect(_timeOffsetOf(plan.url), '231');
    });

    test('reads the transcoding parameters off the base address', () {
      final plan = _plan(
        contextUrl: _serverStreamUrl(format: 'mp3', maxBitRate: '128'),
      );
      expect(plan!.format, 'mp3');
      expect(plan.maxBitRate, 128);
    });

    test('falls back to a plain seek for non-server sources', () {
      expect(
        _plan(loadedSourceUrl: 'https://m701.music.126.net/song.mp3'),
        isNull,
      );
      expect(_plan(loadedSourceUrl: 'file:///data/cache/song.flac'), isNull);
      expect(
        _plan(contextUrl: _serverStreamUrl(path: '/rest/getCoverArt')),
        isNull,
      );
    });

    test('never reloads when the source belongs to another song', () {
      expect(
        _plan(
          contextSongId: _otherSongId,
          contextUrl: _serverStreamUrl(id: _otherSongId),
          loadedSourceUrl: _serverStreamUrl(id: _otherSongId),
        ),
        isNull,
      );
    });

    test('honours the legacy judgement for non-pipelined servers', () {
      // 明确识别出的非 MusicFlow / 老服务端:直传流本身可字节 seek,重拉反而
      // 会把行为改坏 → 保持源内 seek。
      expect(
        _plan(contextUrl: _serverStreamUrl(), serverPipelinedHttp: false),
        isNull,
      );
    });

    test('seeks to the very beginning without a timeOffset parameter', () {
      final plan = _plan(
        target: Duration.zero,
        contextUrl: _serverStreamUrl(timeOffset: '183'),
      );
      expect(plan, isNotNull);
      expect(
        Uri.parse(plan!.url).queryParameters.containsKey('timeOffset'),
        isFalse,
      );
    });
  });

  group('serverPipesAllHttpStreams', () {
    test('accepts this server however the type string is spelled', () {
      for (final type in <String>['MusicFlow', 'musicflow', 'MusicFlow-web']) {
        expect(
          serverPipesAllHttpStreams(serverType: type, serverVersion: '4.0.14'),
          isTrue,
          reason: type,
        );
      }
    });

    test('tolerates a v-prefixed or decorated version string', () {
      expect(
        serverPipesAllHttpStreams(
          serverType: 'MusicFlow',
          serverVersion: 'v4.0.14',
        ),
        isTrue,
      );
      expect(
        serverPipesAllHttpStreams(
          serverType: 'MusicFlow',
          serverVersion: 'MusicFlow 4.0.14',
        ),
        isTrue,
      );
    });

    test('still rejects other server implementations', () {
      expect(
        serverPipesAllHttpStreams(
          serverType: 'navidrome',
          serverVersion: '0.54.0',
        ),
        isFalse,
      );
      expect(
        serverPipesAllHttpStreams(
          serverType: 'MusicFlow',
          serverVersion: '3.0.46',
        ),
        isFalse,
      );
    });
  });
}
