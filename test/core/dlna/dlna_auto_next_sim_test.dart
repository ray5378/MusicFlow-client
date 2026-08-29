import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/dlna/dlna_manager.dart';
import 'package:musicflow_client/core/dlna/dlna_models.dart';

/// ============================================================================
/// 本地模拟 DLNA 设备（真实 HTTP/SOAP 服务）
/// ----------------------------------------------------------------------------
/// 在 127.0.0.1 上起一个 HttpServer，暴露 AVTransport / RenderingControl 控制
/// 端点，忠实回放 SOAP 信封，并用内部状态机模拟「播放中进度推进 → 播放结束」。
/// 通过 [endMode] / [reportPosition] 可分别复现不同设备的停播行为：
///   - keepPlaying：放完仍上报 PLAYING（依赖 nearEnd / wallDone 触发自动续播）
///   - stopAfterEnd：放完转 STOPPED（deviceEnded 触发）
///   - rawHTTP：duration/position 恒 0（依赖墙钟 wallDone 兜底）
/// ============================================================================
class _FakeDlnaDevice {
  HttpServer? _server;
  late int _port;

  /// 设备当前传输状态
  String state = 'STOPPED';
  String _currentUri = '';

  /// GetPositionInfo 回报的时长（秒）；0 表示设备不报时长（rawHTTP 场景）。
  int duration = 0;

  /// 放完后行为。
  String endMode = 'keepPlaying';

  /// 是否回报真实进度；false 表示恒返回 position=0/duration=0（rawHTTP）。
  bool reportPosition = true;

  /// 进度推进倍速（模拟设备比墙钟快，缩短测试等待时间）。
  double speed = 1.0;

  /// stopAfterEnd 且 duration==0 时，播放 start 后延迟多久转 STOPPED。
  Duration stopDelay = const Duration(milliseconds: 3500);

  /// 每次 Play 后「实际开始播放」的曲目直链（按 Play 顺序如实记录，含单曲/回环重复，
  /// 用于断言自动续播真实下发与多首连播/循环）。
  final List<String> playedUris = [];

  DateTime? _playStartAt;
  bool _willStopByDelay = false;
  Timer? _stopTimer;

  String get controlUrl => 'http://127.0.0.1:$_port/AVTransport/control';
  String get renderingUrl => 'http://127.0.0.1:$_port/RenderingControl/control';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _port = _server!.port;
    _server!.listen(_handle);
  }

  Future<void> close() async {
    _stopTimer?.cancel();
    await _server?.close(force: true);
  }

  Future<void> _handle(HttpRequest req) async {
    String body = '';
    try {
      body = await utf8.decoder.bind(req).join();
    } catch (_) {}
    final soapAction = (req.headers.value('soapaction') ?? '')
        .replaceAll('"', '');
    final action = soapAction.split('#').last;

    String inner = '';
    switch (action) {
      case 'GetTransportInfo':
        if (endMode == 'stopAfterEnd' &&
            (duration > 0 ? _ended() : _willStopByDelay)) {
          state = 'STOPPED';
        }
        inner = '<CurrentTransportState>$state</CurrentTransportState>'
            '<CurrentTransportStatus>OK</CurrentTransportStatus>'
            '<CurrentSpeed>1</CurrentSpeed>';
        break;

      case 'GetPositionInfo':
        var pos = 0;
        var dur = duration;
        if (reportPosition && duration > 0) {
          final elapsed = _playSecs() * speed;
          pos = elapsed.floor().clamp(0, duration);
          if (endMode == 'stopAfterEnd' && elapsed >= duration) {
            state = 'STOPPED';
            pos = duration;
          }
        }
        if (endMode == 'stopAfterEnd' && duration == 0 && _willStopByDelay) {
          state = 'STOPPED';
        }
        inner = '<TrackDuration>${_hms(dur)}</TrackDuration>'
            '<RelTime>${_hms(pos)}</RelTime>'
            '<TrackURI>$_currentUri</TrackURI>';
        break;

      case 'SetAVTransportURI':
        _currentUri =
            RegExp(r'<CurrentURI>([^<]*)</CurrentURI>').firstMatch(body)?.group(1) ?? '';
        break;

      case 'SetNextAVTransportURI':
        // 仅预置下一首直链，实际播放由 SetAVTransportURI + Play 决定，设备端无需记录。
        break;

      case 'Play':
        state = 'PLAYING';
        _playStartAt = DateTime.now();
        if (endMode == 'stopAfterEnd' && duration == 0) {
          _willStopByDelay = false;
          _stopTimer?.cancel();
          _stopTimer = Timer(stopDelay, () => _willStopByDelay = true);
        }
        if (_currentUri.isNotEmpty) {
          playedUris.add(_currentUri);
        }
        break;

      case 'Stop':
        state = 'STOPPED';
        break;

      case 'Pause':
        state = 'PAUSED';
        break;

      case 'GetVolume':
        inner = '<CurrentVolume>30</CurrentVolume>';
        break;

      case 'GetMute':
        inner = '<CurrentMute>0</CurrentMute>';
        break;
    }

    await _respond(req, action, inner);
  }

  bool _ended() => _playStartAt != null &&
      DateTime.now().difference(_playStartAt!).inMilliseconds /
              1000.0 *
              speed >=
          duration;

  double _playSecs() => _playStartAt == null
      ? 0
      : DateTime.now().difference(_playStartAt!).inMilliseconds / 1000.0;

  static String _hms(int sec) {
    final h = (sec ~/ 3600).toString().padLeft(2, '0');
    final m = ((sec % 3600) ~/ 60).toString().padLeft(2, '0');
    final s = (sec % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  Future<void> _respond(
    HttpRequest req,
    String action,
    String inner,
  ) async {
    const ns = 'urn:schemas-upnp-org:service:AVTransport:1';
    final out = '<?xml version="1.0"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
        '<s:Body><u:${action}Response xmlns:u="$ns">$inner</u:${action}Response>'
        '</s:Body></s:Envelope>';
    req.response.statusCode = 200;
    req.response.headers.contentType = ContentType('text', 'xml', charset: 'utf-8');
    req.response.write(out);
    await req.response.close();
  }
}

DlnaDevice _device(_FakeDlnaDevice fake) => DlnaDevice(
      id: 'sim-device',
      name: '模拟电视',
      location: 'http://127.0.0.1/desc.xml',
      lastSeen: DateTime(2026, 1, 1),
      avTransportUrl: fake.controlUrl,
      renderingControlUrl: fake.renderingUrl,
    );

List<DlnaCastTrack> _tracks({int? duration}) =>
    [for (var i = 0; i < 4; i++) _track('song$i', '曲$i', duration)];

DlnaCastTrack _track(String id, String title, int? duration) =>
    DlnaCastTrack(songId: id, title: title, artist: '模拟歌手', duration: duration);

void main() {
  late _FakeDlnaDevice fake;
  late DlnaManager manager;

  setUp(() async {
    fake = _FakeDlnaDevice();
    await fake.start();
    manager = DlnaManager();
    await manager.init(
      streamUrlBuilder: (songId) async => 'http://server/stream/$songId.m3u8',
    );
  });

  tearDown(() async {
    await manager.dispose();
    await fake.close();
  });

  /// 订阅 onTrackChanged，记录「跳曲瞬间」带时间戳(index)轨迹，用于观测自动下一首
  /// 是否真下发、是否重复跳/跳过了曲目。
  Future<List<(double, int)>> traceIndex(Duration window) async {
    final sw = Stopwatch()..start();
    final changes = <(double, int)>[];
    manager.onTrackChanged = (i) =>
        changes.add((sw.elapsedMilliseconds / 1000.0, i));
    while (sw.elapsed < window) {
      await Future.delayed(const Duration(milliseconds: 200));
    }
    sw.stop();
    final trace = changes.isEmpty
        ? <(double, int)>[(sw.elapsedMilliseconds / 1000.0, manager.castQueueIndex)]
        : changes;
    debugPrint('[SIM-TRACE] ${sw.elapsedMilliseconds / 1000.0}s 跳曲轨迹=$trace '
        '最终index=${manager.castQueueIndex} 设备实际播放列表=${fake.playedUris}');
    return trace;
  }

  test('【模拟设备·正常播放尾】放完自动推下一首，且不重复跳曲', () async {
    fake.duration = 6; // 设备回报 6s 时长
    fake.reportPosition = true;
    fake.endMode = 'keepPlaying';
    fake.speed = 6.0; // 进度 6 倍速，2s 内就到尾
    manager.setPlayMode('all');

    final ok = await manager.startCast(
      _device(fake),
      _tracks(duration: 6),
    );
    expect(ok, isTrue, reason: '应成功对模拟设备建立投屏(A档)');
    // 初始从队列第 0 首开始（onTrackChanged 订阅在 traceIndex 后才挂上，故在投屏建立后立即断言）。
    expect(manager.castQueueIndex, 0, reason: '投屏应自队列第 0 首开始');

    final trace = await traceIndex(const Duration(seconds: 7));

    expect(trace.length, greaterThan(0));
    expect(trace.last.$2, greaterThan(0), reason: '播放结束后应自动推到下一首');
    // 进度按 1 首 1 推：多首曲目像放完时允许逐首推进到 1、2…，但不得跨曲跳歌。
    // 先去掉重复广播的同一 index（如 `(4,1),(4,1)` 实为同一次推进被记录两次），
    // 再断言相邻两次推进的曲目下标严格 +1，即能拦截「双推/skip」类竞态。
    final advanced = <int>[];
    for (final e in trace) {
      if (advanced.isEmpty || advanced.last != e.$2) advanced.add(e.$2);
    }
    expect(advanced, isNotEmpty);
    for (var k = 1; k < advanced.length; k++) {
      expect(advanced[k] - advanced[k - 1], 1,
          reason: '不得跨曲跳歌（应逐首 1→2→3…推进），观测到 '
              '${advanced[k - 1]}→${advanced[k]}');
    }
    expect(fake.playedUris.length, greaterThanOrEqualTo(2));
    expect(fake.playedUris[1], contains('song1'),
        reason: '设备应实际收到第 1 首的直链');
  });

  test('【模拟设备 rawHTTP】设备恒报 duration/position=0 时，靠墙钟兜底自动续播', () async {
    fake.duration = 0;
    fake.reportPosition = false;
    fake.endMode = 'keepPlaying';
    // 真实时长由 track.duration 提供（Song 层数据）
    manager.setPlayMode('all');

    final ok = await manager.startCast(
      _device(fake),
      _tracks(duration: 4),
    );
    expect(ok, isTrue);

    final trace = await traceIndex(const Duration(seconds: 6));

    expect(trace.last.$2, greaterThan(0),
        reason: '设备不报时长/进度时，墙钟 wallDone 应兜底推进');
    // rawHTTP 设备恒报 position=0，客户端不应误走「仅对齐游标」的 _alignToNext，
    // 而是应主动 SetAVTransportURI 下发下一首直链，设备才真正收到 song1。
    expect(fake.playedUris.length, greaterThanOrEqualTo(2));
    expect(fake.playedUris[1], contains('song1'),
        reason: 'rawHTTP 设备应实际收到第 1 首直链（走 advance，非仅对齐游标）');
  });

  test('【模拟设备 停播】设备放完自然转 STOPPED 时，deviceEnded 触发自动续播', () async {
    fake.duration = 0;
    fake.reportPosition = false;
    fake.endMode = 'stopAfterEnd';
    // 设备播放约 5s 后自然转 STOPPED，确保轮询采样累计足够 wall-clock 播放时长，
    // 使 deviceEnded(playedEnough>=3s) 能判定「确已实质播放过」。
    fake.stopDelay = const Duration(milliseconds: 5000);
    // 真实时长未知(0)：wallDone 不参与，改由 deviceEnded 判定（已实质播放过）。
    manager.setPlayMode('all');

    final ok = await manager.startCast(
      _device(fake),
      _tracks(duration: null),
    );
    expect(ok, isTrue);

    final trace = await traceIndex(const Duration(seconds: 9));

    expect(trace.last.$2, greaterThan(0),
        reason: '设备放完转 STOPPED 后 deviceEnded 应自动续播');
    expect(fake.playedUris.length, greaterThanOrEqualTo(2));
    expect(fake.playedUris[1], contains('song1'),
        reason: '设备应实际收到第 1 首的直链');
  });

  /// 从设备实际收到的直链列表中解析每首 song 序号（用于多首连播/循环断言）。
  List<String> orderedSongs(_FakeDlnaDevice d) =>
      d.playedUris.map((u) {
        final m = RegExp(r'song(\d)').firstMatch(u);
        return m == null ? '?' : m.group(1)!;
      }).toList();

  test('【播放模式 order】顺序连播4首 0→1→2→3，末首放完停播不回头', () async {
    fake.duration = 6;
    fake.reportPosition = true;
    fake.endMode = 'keepPlaying';
    fake.speed = 12.0; // 进度 12 倍速，快速到尾触发 nearEnd
    manager.setPlayMode('order');

    final ok = await manager.startCast(
      _device(fake),
      _tracks(duration: 6),
    );
    expect(ok, isTrue);

    final trace = await traceIndex(const Duration(seconds: 20));

    // 顺序模式应把 4 首都实际下发到设备，且按 0→1→2→3 的顺序播放。
    expect(orderedSongs(fake), ['0', '1', '2', '3'],
        reason: 'order 模式应顺序下发全部 4 首（song0..song3）');
    // 末首(song3)放完即停止：不回头循环、不跳曲。
    expect(trace.last.$2, 3,
        reason: 'order 模式下末首播放结束后应停下，索引停在 3');
    expect(fake.playedUris.length, 4,
        reason: 'order 模式不应在末首之后再推新曲');
  });

  test('【播放模式 one】单曲循环：放完重播当前首，不切歌、不跳曲', () async {
    fake.duration = 6;
    fake.reportPosition = true;
    fake.endMode = 'keepPlaying';
    fake.speed = 12.0;
    manager.setPlayMode('one');

    final ok = await manager.startCast(
      _device(fake),
      _tracks(duration: 6),
    );
    expect(ok, isTrue);

    await traceIndex(const Duration(seconds: 6));

    // 单曲循环：游标始终停在 0，设备只反复播 song0，绝不切到 song1。
    expect(manager.castQueueIndex, 0, reason: '单曲循环不应切歌');
    expect(fake.playedUris.every((u) => u.contains('song0')), isTrue,
        reason: '单曲循环设备应始终只播同一首');
    expect(orderedSongs(fake).toSet(), {'0'},
        reason: '单曲循环只下发 song0');
  });

  test('【播放模式 shuffle】随机切到别首并真下发，游标不越界', () async {
    fake.duration = 6;
    fake.reportPosition = true;
    fake.endMode = 'keepPlaying';
    fake.speed = 12.0;
    manager.setPlayMode('shuffle');

    final ok = await manager.startCast(
      _device(fake),
      _tracks(duration: 6),
    );
    expect(ok, isTrue);

    final trace = await traceIndex(const Duration(seconds: 6));

    // 随机模式：真实切到了别的首(index != 当前)，且游标仍在队内，设备确实收到新曲直链。
    // 用「设备实际播过一首非初始曲」而非「末次跳曲 != 0」判定——shuffle 在观测窗口内
    // 可能随机绕回 0，用末次索引断言会误报（历史偶发 flaky）。
    expect(orderedSongs(fake).toSet(), isNot({'0'}),
        reason: 'shuffle 应切到随机别的首');
    expect(trace.last.$2, inInclusiveRange(0, 3), reason: '随机游标不应越界');
    expect(fake.playedUris.length, greaterThan(1),
        reason: 'shuffle 应把随机到的下一首下发给设备');
  });

  test('【多首连播 all】完整播完队列并回环 song0，全程逐一首推进不跳曲', () async {
    fake.duration = 6;
    fake.reportPosition = true;
    fake.endMode = 'keepPlaying';
    fake.speed = 12.0;
    manager.setPlayMode('all');

    final ok = await manager.startCast(
      _device(fake),
      _tracks(duration: 6),
    );
    expect(ok, isTrue);

    final trace = await traceIndex(const Duration(seconds: 26));

    // 列表循环：前 5 次播放应为 0→1→2→3→0（顺序播完一整轮并回环到 song0）。
    expect(orderedSongs(fake).take(5), ['0', '1', '2', '3', '0'],
        reason: 'all 模式应 0→1→2→3 顺序播完并回环到 song0');
    // 整个过程中游标逐首推进且出现过回环(回到 0)，说明多次续播互斥正常、无双推/跳过。
    expect(trace.any((t) => t.$2 == 0), isTrue,
        reason: '列表循环应回环到队列第 0 首');
    expect(trace.length, greaterThanOrEqualTo(5),
        reason: '应发生 ≥5 次游标变化(0..4 轮)，验证多次连续自动续播');
  });
}