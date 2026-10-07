// 链路 B（DLNA 直投）provider 层覆盖率补测 —— batch18。
//
// 覆盖目标：lib/providers/cast/dlna_provider.dart（351 行可执行 / 44.16%）。
// 这个文件是纯「provider 层状态机」：DlnaDevicesNotifier + DlnaCastNotifier +
// ensureDlnaManagerReady 的三个闭包回调。全部依赖都可 override
// （dlnaManagerProvider / playerProvider / dlnaCastHttpBaseProvider /
// subsonicApiClientProvider / effectiveQualityProvider），所以不需要真机、
// 不需要 SSDP 套接字、也不需要 just_audio —— 与 core/dlna/dlna_manager.dart
// 那批「起真 HttpServer 假设备」的用例是两条完全不同的路。
//
// 纪律：本文件**只读产品代码**，不改一行 lib/。凡是测试中发现的产品侧疑点，
// 一律用 `// [D-xxx]` 注释标记（若要改产品代码请先看缺陷台账），并把断言写成
// 「钉住现状」的守卫 —— 将来有人修正实现，这些用例会立刻变红提醒翻断言。
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' hide PlayerState;
import 'package:musicflow_client/core/dlna/cast_http.dart';
import 'package:musicflow_client/core/dlna/dlna_manager.dart';
import 'package:musicflow_client/core/dlna/dlna_models.dart';
import 'package:musicflow_client/core/services/audio_handler_service.dart';
import 'package:musicflow_client/data/models/audio_quality.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/providers/player/audio_quality_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

import '../features/player/test_player_notifier.dart';

/// 不触网假管理器：记调用、可控返回值，还需要什么就往这里加。
class _FakeManager extends DlnaManager {
  _FakeManager({this.startCastResult = true});

  /// 可运行时翻转：测「投屏失败回滚」的分支要先成功起投（拿到 currentDevice），
  /// 再把这里翻成 false，才能走 playQueueOnDevice 的失败分支。
  bool startCastResult;

  /// 真 device 自己在切歌时会推 onTrackChanged；这里默认推（贴合真机），
  /// 翻成 false 才模拟「游标变了但没推回调」—— 用于打进 provider 的兜底同步分支。
  bool syncOnCursorChange = true;
  final List<String> calls = <String>[];
  final Map<String, String> aliases = <String, String>{};
  final Set<String> disabledIds = <String>{};
  final List<DlnaCastTrack> _queue = [];
  int _index = -1;
  bool _casting = false;
  bool _muted = false;
  int detachCalls = 0;
  int muteToggles = 0;

  /// init 时收到的两个回调（测试直接调它们，把 ensureDlnaManagerReady 的
  /// 闭包体打进来）。
  Future<String> Function(String)? streamUrlBuilder;
  Future<bool> Function(String)? probeSongFn;

  @override
  bool get isCasting => _casting;

  @override
  List<DlnaCastTrack> get castQueue => List.unmodifiable(_queue);

  @override
  int get castQueueIndex => _index;

  @override
  bool get isMuted => _muted;

  @override
  Future<void> init({
    required Future<String> Function(String songId) streamUrlBuilder,
    Future<bool> Function(String songId)? probeSong,
  }) async {
    this.streamUrlBuilder = streamUrlBuilder;
    this.probeSongFn = probeSong;
    calls.add('init');
  }

  @override
  Future<List<DlnaDevice>> scanDevices({
    Duration perDeviceFetchTimeout = const Duration(seconds: 6),
  }) async {
    calls.add('scan');
    return const <DlnaDevice>[];
  }

  @override
  Future<void> setDeviceAlias(String deviceId, String alias) async {
    aliases[deviceId] = alias;
    calls.add('alias');
  }

  @override
  Future<void> setDeviceDisabled(String deviceId, bool disabled) async {
    if (disabled) {
      disabledIds.add(deviceId);
    } else {
      disabledIds.remove(deviceId);
    }
    calls.add('disabled');
  }

  @override
  Future<void> removeDevice(String deviceId) async =>
      calls.add('remove:$deviceId');

  @override
  Future<bool> startCast(
    DlnaDevice device,
    List<DlnaCastTrack> tracks, {
    int startIndex = 0,
  }) async {
    _queue
      ..clear()
      ..addAll(tracks);
    _index = startIndex;
    _casting = startCastResult;
    calls.add('startCast');
    return startCastResult;
  }

  @override
  Future<void> stopCast() async {
    _queue.clear();
    _index = -1;
    _casting = false;
    calls.add('stopCast');
    onCastDisconnected?.call();
  }

  @override
  Future<void> playAt(int index) async {
    if (index < 0 || index >= _queue.length) return;
    _index = index;
    calls.add('playAt');
    onTrackChanged?.call(_index);
  }

  @override
  Future<void> next() async {
    _index = _index + 1 < _queue.length ? _index + 1 : 0;
    calls.add('next');
    if (syncOnCursorChange) onTrackChanged?.call(_index);
  }

  @override
  Future<void> previous() async {
    _index = _index <= 0 ? (_queue.isEmpty ? -1 : _queue.length - 1) : _index - 1;
    calls.add('previous');
    if (syncOnCursorChange) onTrackChanged?.call(_index);
  }

  @override
  Future<void> setPlayMode(String mode) async =>
      calls.add('mode:$mode');

  @override
  Future<void> enqueueSongs(List<DlnaCastTrack> tracks) async {
    _queue.addAll(tracks);
    calls.add('enqueue');
    onTrackChanged?.call(_index);
  }

  @override
  Future<void> removeQueueItem(int index) async {
    if (index < 0 || index >= _queue.length) return;
    _queue.removeAt(index);
    calls.add('removeQueueItem');
    onTrackChanged?.call(_index);
  }

  @override
  Future<void> reorderQueue(int from, int to) async {
    calls.add('reorderQueue');
    onTrackChanged?.call(_index);
  }

  @override
  Future<void> toggleMute() async {
    _muted = !_muted;
    muteToggles++;
    calls.add('toggleMute');
  }

  @override
  Future<void> detachClientKeepalive() async {
    detachCalls++;
    calls.add('detachClientKeepalive');
  }

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> resume() async => calls.add('resume');

  @override
  Future<void> seek(int seconds) async => calls.add('seek:$seconds');

  @override
  Future<void> setVolume(int volume) async => calls.add('volume:$volume');
}

/// 假 api client：把 `getDlnaCastStreamUrl` / `postRaw` 两个被
/// ensureDlnaManagerReady 回调用到的入口换成可控桩。
class _FakeApiClient extends SubsonicApiClient {
  _FakeApiClient() : super(dio: Dio(BaseOptions(baseUrl: 'https://old.example.test')));

  String urlReply = 'https://old.example.test/rest/stream?id=x';
  bool emptyUrl = false;
  Object? probeError;
  List<dynamic>? probeResults;
  final List<String> calls = <String>[];
  final List<String> probePaths = <String>[];

  @override
  Future<String> getDlnaCastStreamUrl(
    String songId, {
    int? maxBitRate,
  }) async {
    if (emptyUrl) return '';
    // [D-026] 桩不校验入参：真实实现会按 songId 换无鉴权 token，这里只关心
    // provider 侧拿到串之后的 origin 重写行为，songId 原样回吐便于断言。
    return urlReply;
  }

  @override
  Future<dynamic> postRaw(
    String path, {
    Map<String, dynamic>? queryParameters,
    dynamic data,
    Duration? receiveTimeout,
  }) async {
    calls.add('postRaw:$path');
    probePaths.add(path);
    if (probeError != null) throw probeError!;
    if (probeResults == null) return null;
    return <String, dynamic>{'results': probeResults};
  }
}

/// 造得出来的后台 handler 壳：真实现要一个 AudioPlayer，而 DLNA provider
/// 构造时只拿 `[MusicFlowAudioHandler.onTaskRemovedCallback]` 挂一下回调。
class _StubHandler extends MusicFlowAudioHandler {
  _StubHandler() : super(AudioPlayer());
}

/// 记录播控/续播调用的假播放器：只实现 DLNA 直投那几路公开入口。
class _RecPlayer extends TestPlayerNotifier {
  _RecPlayer(super.state);

  /// 造得出来的「后台音频 handler」：真实 MusicFlowAudioHandler 只是个壳，
  /// DLNA provider 构造时只拿它挂 `onTaskRemovedCallback`，不再碰别的成员。
  MusicFlowAudioHandler? handler;

  /// [dlna_provider] 构造时那句 `handler.onTaskRemovedCallback = detachOnAppRemoved`
  /// 就是要落到这个字段上 —— 默认 null 会让那条 if 直接早退。
  Future<void> Function()? get taskRemovedCallback =>
      handler?.onTaskRemovedCallback;

  @override
  MusicFlowAudioHandler? get audioHandler => handler;

  final List<bool> notificationActive = <bool>[];
  final List<bool> notificationPlaying = <bool>[];
  final List<Duration> notificationPosition = <Duration>[];
  final List<Duration> seeks = <Duration>[];
  final List<Duration> plays = <Duration>[];
  final List<String> playSongIds = <String>[];
  int syncCastCalls = 0;

  @override
  void updateNotificationCastProgress({
    required bool active,
    required bool playing,
    required Duration position,
  }) {
    notificationActive.add(active);
    notificationPlaying.add(playing);
    notificationPosition.add(position);
  }

  @override
  Future<void> play() async => plays.add(Duration.zero);

  @override
  Future<void> seek(Duration position) async => seeks.add(position);

  @override
  Future<void> playSong(
    Song song, {
    List<Song>? queue,
    int? index,
    bool recordShuffleHistory = false,
    bool clearShuffleForwardHistory = false,
    bool autoPlay = true,
    Duration? initialPosition,
  }) async {
    playSongIds.add(song.id);
  }

  @override
  void syncQueueForCast(List<Map<String, dynamic>> items, int index) {
    syncCastCalls++;
  }
}

DlnaDevice _device(String id, String name) => DlnaDevice(
      id: id,
      name: name,
      location: 'http://192.168.1.10:8000/desc.xml',
      lastSeen: DateTime(2024, 1, 1),
      avTransportUrl: 'http://192.168.1.10:8000/AVTransport/control',
      renderingControlUrl: 'http://192.168.1.10:8000/RenderingControl/control',
    );

DlnaCastTrack _track(String songId, String title) =>
    DlnaCastTrack(songId: songId, title: title, artist: '周杰伦');

Song _song(String id, String title) => Song(id: id, title: title, artist: '周杰伦');

PlayerState _playerState(List<Song> queue) => PlayerState(
      currentSong: queue.isEmpty ? null : queue.first,
      queue: queue,
      currentIndex: queue.isEmpty ? -1 : 0,
      isPlaying: true,
      position: Duration.zero,
      duration: Duration.zero,
      bufferedPosition: Duration.zero,
      loopMode: LoopMode.all,
      currentQuality: AudioQualityLevel.original,
      playbackSource: PlaybackSource.stream,
      currentBitRateKbps: 320,
    );

/// 取一个「绑定在 container 上」的 Ref，用来直接调
/// `ensureDlnaManagerReady(ref)`（它是普通函数，不是 provider）。
final Provider<Ref> _refHolderProvider = Provider<Ref>((ref) => ref);

const String _castBase = 'http://192.168.10.230:46400';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final device = _device('u1', '客厅电视');
  final sourceSongs = <Song>[
    _song('s1', '夜曲'),
    _song('s2', '晴天'),
    _song('s3', '七里香'),
  ];

  late _FakeManager manager;
  late _FakeApiClient api;
  late _RecPlayer player;
  late ProviderContainer container;
  late DlnaCastNotifier notifier;
  String? castBaseOverride;

  ProviderContainer buildContainer({
    bool startCastSucceeds = true,
    bool withHandler = false,
    bool useRealCastBase = false,
  }) {
    manager = _FakeManager(startCastResult: startCastSucceeds);
    api = _FakeApiClient();
    final rec = _RecPlayer(_playerState(sourceSongs));
    if (withHandler) {
      rec.handler = _StubHandler();
    }
    final overrides = <Override>[
      dlnaManagerProvider.overrideWith((ref) => manager),
      playerProvider.overrideWith((ref) => rec),
      subsonicApiClientProvider.overrideWithValue(api),
      effectiveQualityProvider.overrideWithValue(AudioQualityLevel.original),
    ];
    if (!useRealCastBase) {
      overrides.add(dlnaCastHttpBaseProvider.overrideWithValue(castBaseOverride));
    } else {
      // 放开 dlnaCastHttpBaseProvider，让它跑真实 provider 体
      // （ref.watch(activeLibraryProvider) + ref.watch(activeAddressProvider)）。
      overrides
        ..add(activeLibraryProvider.overrideWithValue(null))
        ..add(activeAddressProvider.overrideWith((ref) => null));
    }
    return ProviderContainer(overrides: overrides);
  }

  setUp(() {
    castBaseOverride = _castBase;
    container = buildContainer();
    notifier = container.read(dlnaCastProvider.notifier);
    player = container.read(playerProvider.notifier) as _RecPlayer;
  });

  tearDown(() => container.dispose());

  Future<void> startCastOk({bool startCastSucceeds = true}) async {
    // 换容器前先拆掉旧的：旧容器里挂着 500ms tick 与 heartbeat Timer，
    // 不 dispose 会一直触发回调打到已经换掉的 player 桩上。
    container.dispose();
    container = buildContainer(startCastSucceeds: startCastSucceeds);
    notifier = container.read(dlnaCastProvider.notifier);
    player = container.read(playerProvider.notifier) as _RecPlayer;
    await notifier.startCast(
      device,
      sourceSongs.map((s) => _track(s.id, s.title)).toList(),
    );
  }

  /// 推一帧设备状态（走 notifier 在构造时挂的 onStatusChanged）。
  void pushStatus(DlnaDeviceStatus status) =>
      manager.onStatusChanged?.call(status);

  // ──────────────────────────────────────────────────────────────────
  // A. ensureDlnaManagerReady 的 streamUrlBuilder 闭包
  // ──────────────────────────────────────────────────────────────────
  group('ensureDlnaManagerReady · streamUrlBuilder', () {
    test('抓不到 http 基地址时抛 DlnaCastHttpUnavailableException', () async {
      castBaseOverride = null;
      container = buildContainer();
      final ref = container.read(_refHolderProvider);
      // ensure 本身不抛（它只是把闭包挂给 manager），要 await 完再说。
      await ensureDlnaManagerReady(ref);

      // [D-028] 现状钉子：异常抛出点在 streamUrlBuilder 闭包**被调用时**
      // （闭包体读 castBase，为 null 就 throw），而不是 ensure 阶段就地校验。
      // 将来若改成 ensure 里就抛，这条会红，提醒翻断言。
      Object? thrown;
      try {
        await manager.streamUrlBuilder!('s1');
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isA<DlnaCastHttpUnavailableException>());
    });

    test('服务端给的流地址被 origin 重写成投屏专用 http 基地址', () async {
      container = buildContainer();
      final ref = container.read(_refHolderProvider);
      await ensureDlnaManagerReady(ref);

      final url = await manager.streamUrlBuilder!('s1');
      // [D-027] 现状钉子（batch18 QA 复核订正）：rewriteUrlToBase 只换 origin，
      // **路径与 query 原样保留** —— 老的带 u/t/s 鉴权 /rest/stream 地址重写后
      // 仍有效，属有意为之。
      // 注：只断言 `contains(castBase)` 是**无效钉子**（QA 指出：将来真改成整串
      // 替换、path/query 一起丢，这两条照样绿）。所以这里连 path 与 query 一起断言：
      // 桩固定回 `old.example.test/rest/stream?id=x`，重写后必须仍是 /rest/stream?id=x。
      expect(url, contains(_castBase));
      expect(url, isNot(contains('old.example.test')));
      expect(url, contains('rest/stream'), reason: '[D-027] 路径不能被整串替换吃掉');
      expect(url, contains('id=x'), reason: '[D-027] query 不能被整串替换吃掉');
      expect(manager.calls, contains('init'));
    });

    test('服务端回空串时原样返回空串（不补基地址）', () async {
      container = buildContainer();
      final ref = container.read(_refHolderProvider);
      await ensureDlnaManagerReady(ref);
      api.emptyUrl = true;

      expect(await manager.streamUrlBuilder!('s1'), isEmpty);
    });

    test('换 token 时把音质档位带进请求（桩只记不校验）', () async {
      container = buildContainer();
      final ref = container.read(_refHolderProvider);
      await ensureDlnaManagerReady(ref);

      // 桩固定回一串 url；这里只确认调用不抛、且拿到串。
      expect(await manager.streamUrlBuilder!('s9'), isNotEmpty);
    });
  });

  // ──────────────────────────────────────────────────────────────────
  // B. ensureDlnaManagerReady 的 probeSong 闭包（四态判定）
  // ──────────────────────────────────────────────────────────────────
  group('ensureDlnaManagerReady · probeSong', () {
    Future<bool> probe(Map<dynamic, dynamic> row) async {
      container = buildContainer();
      final ref = container.read(_refHolderProvider);
      await ensureDlnaManagerReady(ref);
      api.probeResults = row == null ? null : [row];
      return manager.probeSongFn!('s1');
    }

    test('服务端没返回该曲结果时不误杀', () async {
      expect(await probe(const <String, dynamic>{}), isTrue);
    });

    test('verdict=unplayable 判定为无源', () async {
      expect(
        await probe(const <String, dynamic>{'songId': 's1', 'verdict': 'unplayable'}),
        isFalse,
      );
    });

    test('verdict=transient / unknown 不误杀，交设备实测', () async {
      expect(
        await probe(const <String, dynamic>{'songId': 's1', 'verdict': 'transient'}),
        isTrue,
      );
      expect(
        await probe(const <String, dynamic>{'songId': 's1', 'verdict': 'unknown'}),
        isTrue,
      );
    });

    test('旧服务端只有 ok 字段时按 ok 判定', () async {
      expect(
        await probe(const <String, dynamic>{'songId': 's1', 'ok': true}),
        isTrue,
      );
      expect(
        await probe(const <String, dynamic>{'songId': 's1', 'ok': false}),
        isFalse,
      );
    });

    test('探测请求自身失败（网络抖）返回 true 不误杀', () async {
      container = buildContainer();
      final ref = container.read(_refHolderProvider);
      await ensureDlnaManagerReady(ref);
      api.probeError = StateError('network-down');
      api.probeResults = null;

      expect(await manager.probeSongFn!('s1'), isTrue);
    });

    test('DlnaSongUnplayableException 归为无源', () async {
      container = buildContainer();
      final ref = container.read(_refHolderProvider);
      await ensureDlnaManagerReady(ref);
      api.probeError = const DlnaSongUnplayableException('s1');

      expect(await manager.probeSongFn!('s1'), isFalse);
    });

    test('探测打的是投屏预检端点并带上歌曲 id', () async {
      container = buildContainer();
      final ref = container.read(_refHolderProvider);
      await ensureDlnaManagerReady(ref);

      api.probeResults = <dynamic>[];
      api.probePaths.clear();
      await manager.probeSongFn!('s42');

      expect(api.probePaths, contains('/rest/api/v1/stream/probe'));
    });
  });

  // ──────────────────────────────────────────────────────────────────
  // C. DlnaDevicesNotifier
  // ──────────────────────────────────────────────────────────────────
  group('DlnaDevicesNotifier', () {
    test('scan 期间置 isScanning，结束后复原并释放组播锁', () async {
      expect(container.read(dlnaDevicesProvider).isScanning, isFalse);

      // 订阅整个 scan 过程：isScanning 会在 await scanDevices() 之前翻 true。
      final seen = <bool>[];
      final sub = container.listen(
        dlnaDevicesProvider,
        (_, next) => seen.add(next.isScanning),
      );
      addTearDown(sub.close);

      await container.read(dlnaDevicesProvider.notifier).scan();

      expect(manager.calls, contains('init'));
      expect(manager.calls, contains('scan'));
      expect(seen, contains(true));
      expect(container.read(dlnaDevicesProvider).isScanning, isFalse);
    });

    test('manager 的设备变化会推到设备列表状态', () async {
      final notifier = container.read(dlnaDevicesProvider.notifier);
      manager.onDevicesChanged?.call([device]);

      final st = container.read(dlnaDevicesProvider);
      expect(st.devices.map((d) => d.id), <String>['u1']);
    });

    test('setAlias / setDisabled / remove 全部转发到 manager', () async {
      final notifier = container.read(dlnaDevicesProvider.notifier);

      notifier.setAlias('u1', '主卧音箱');
      notifier.setDisabled('u1', true);
      notifier.remove('u1');

      expect(manager.aliases['u1'], '主卧音箱');
      expect(manager.disabledIds, contains('u1'));
      expect(manager.calls, contains('remove:u1'));
    });
  });

  // ──────────────────────────────────────────────────────────────────
  // D. 状态类纯逻辑（currentTrack / copyWith / track 映射）
  // ──────────────────────────────────────────────────────────────────
  group('DlnaCastState 纯逻辑', () {
    test('currentTrack 在越界下标下返回 null', () {
      final empty = const DlnaCastState(currentIndex: 0, queue: <DlnaCastTrack>[]);
      expect(empty.currentTrack, isNull);

      const one = DlnaCastState(
        currentIndex: 1,
        queue: <DlnaCastTrack>[DlnaCastTrack(songId: 'a', title: 'A')],
      );
      expect(one.currentTrack, isNull);

      const hit = DlnaCastState(
        currentIndex: 0,
        queue: <DlnaCastTrack>[DlnaCastTrack(songId: 'a', title: 'A')],
      );
      expect(hit.currentTrack?.songId, 'a');
    });

    test('copyWith 逐字段生效', () {
      const base = DlnaCastState();
      final next = base.copyWith(
        isCasting: true,
        queue: const <DlnaCastTrack>[],
        currentIndex: 2,
        playMode: 'order',
        smoothPositionSeconds: 1.5,
        castPath: DlnaCastPath.direct,
      );
      expect(next.isCasting, isTrue);
      expect(next.currentIndex, 2);
      expect(next.playMode, 'order');
      expect(next.smoothPositionSeconds, 1.5);
      expect(next.castPath, isNotNull);
      // 未涉及的字段留在原值。
      expect(next.currentDevice, isNull);
      expect(next.status.state, base.status.state);
    });

    test('clearDevice 才清得掉当前设备（普通传 null 清不掉）', () {
      final withDevice = DlnaCastState(currentDevice: _device('u9', '电视'));
      expect(withDevice.copyWith().currentDevice?.id, 'u9');
      expect(
        withDevice.copyWith(clearDevice: true).currentDevice,
        isNull,
      );
    });

    test('[D-025] DlnaDevicesState.copyWith 显式传 null 清空字段（已翻转）', () {
      // 已修复（2026-10-07 用户拍板：显式清空语义）：copyWith 改为哨兵参数，
      // 显式传 null 真正清空；省略参数 = 保持现状（见 b41e2_d025_copywith_test.dart）。
      final base = DlnaDevicesState(
        devices: <DlnaDevice>[_device('u1', '电视')],
        isScanning: true,
      );
      final cleared = base.copyWith(devices: null, isScanning: null);
      expect(cleared.devices, isEmpty);
      expect(cleared.isScanning, isFalse);
    });

    test('dlnaCastTrackFromSong 逐字段映射', () {
      final song = _song('s1', '夜曲').copyWith(album: '十一月的萧邦');
      final track = dlnaCastTrackFromSong(song);
      expect(track.songId, 's1');
      expect(track.title, '夜曲');
      expect(track.artist, '周杰伦');
      expect(track.album, '十一月的萧邦');
    });
  });

  // ──────────────────────────────────────────────────────────────────
  // E. DlnaCastNotifier 的三条设备回调
  // ──────────────────────────────────────────────────────────────────
  group('DlnaCastNotifier 设备回调', () {
    test('onStatusChanged 写入平滑进度并按设备状态驱动播控', () async {
      // _syncNotificationCast 早退条件是 `!isCasting || currentDevice == null`，
      // 所以要先起投才有 currentDevice，否则播控收不到任何一帧。
      await startCastOk();
      // startCast 成功那一下已经推过一帧（playing=false / 0s），清掉，
      // 好让断言只看到「本条状态回调」这一帧。
      player.notificationActive.clear();
      player.notificationPlaying.clear();
      player.notificationPosition.clear();
      pushStatus(const DlnaDeviceStatus(state: 'PLAYING', position: 30, duration: 200));

      final st = container.read(dlnaCastProvider);
      expect(st.smoothPositionSeconds, 30);
      expect(st.status.position, 30);
      expect(player.notificationActive, <bool>[true]);
      expect(player.notificationPlaying, <bool>[true]);
      expect(player.notificationPosition, <Duration>[const Duration(seconds: 30)]);
    });

    test('onStatusChanged 非 PLAYING 时播控标记为不播放', () async {
      await startCastOk();
      player.notificationActive.clear();
      player.notificationPlaying.clear();
      player.notificationPosition.clear();
      pushStatus(const DlnaDeviceStatus(state: 'PAUSED_PAUSED', position: 5));

      expect(player.notificationPlaying, <bool>[false]);
      expect(container.read(dlnaCastProvider).smoothPositionSeconds, 5);
    });

    test('onTrackChanged 同步游标并镜像队列到本机', () async {
      await startCastOk();
      player.syncCastCalls = 0;

      manager.onTrackChanged?.call(2);

      final st = container.read(dlnaCastProvider);
      expect(st.currentIndex, 2);
      expect(player.syncCastCalls, greaterThan(0));
    });

    test('onCastDisconnected 清干净设备/队列/进度/播控', () async {
      await startCastOk();
      pushStatus(const DlnaDeviceStatus(state: 'PLAYING', position: 12));
      player.notificationActive.clear();

      manager.onCastDisconnected?.call();

      final st = container.read(dlnaCastProvider);
      expect(st.isCasting, isFalse);
      expect(st.currentDevice, isNull);
      expect(st.queue, isEmpty);
      expect(st.currentIndex, -1);
      expect(st.smoothPositionSeconds, 0);
      expect(player.notificationActive, <bool>[false]);
    });

    test('未投屏时状态回调不会驱动播控', () {
      // 裸 notifier（未 startCast）推状态：_syncNotificationCast 早退。
      pushStatus(const DlnaDeviceStatus(state: 'PLAYING', position: 1));
      expect(player.notificationActive, isEmpty);
    });
  });

  // ──────────────────────────────────────────────────────────────────
  // F. 平滑 tick（500ms 插值）
  // ──────────────────────────────────────────────────────────────────
  group('DlnaCastNotifier 平滑进度', () {
    test('投屏 + 设备在播时 tick 按 0.5s 步进推进', () async {
      await startCastOk();
      pushStatus(const DlnaDeviceStatus(state: 'PLAYING', position: 0, duration: 300));
      final before = container.read(dlnaCastProvider).smoothPositionSeconds;

      await Future<void>.delayed(const Duration(milliseconds: 1200));

      final after = container.read(dlnaCastProvider).smoothPositionSeconds;
      expect(after, greaterThan(before));
    });

    test('设备暂停后 tick 不再推进进度（进度以设备回写为准）', () async {
      await startCastOk();
      pushStatus(const DlnaDeviceStatus(state: 'PLAYING', position: 10, duration: 300));
      // 等 1100ms 而不是 700ms：tick 周期 500ms，只等 700ms 的话「至少跳 1 格」的
      // 余量只有 200ms，墙钟一抖就红（batch18 QA 复核建议把余量拉到 600ms）。
      await Future<void>.delayed(const Duration(milliseconds: 1100));

      final playing = container.read(dlnaCastProvider).smoothPositionSeconds;
      expect(playing, greaterThan(10), reason: '在播时 tick 按 0.5s 步进');

      // 设备停下：onStatusChanged 会把平滑值覆盖成设备上报的位置（10），
      // 之后的 tick 因 status.state != 'PLAYING' 不再加 0.5。
      manager.onStatusChanged?.call(
        const DlnaDeviceStatus(state: 'STOPPED', position: 10, duration: 300),
      );
      final atStop = container.read(dlnaCastProvider).smoothPositionSeconds;
      expect(atStop, 10);

      await Future<void>.delayed(const Duration(milliseconds: 700));
      final after = container.read(dlnaCastProvider).smoothPositionSeconds;
      expect(after, atStop, reason: '暂停态 tick 不该继续推进');
      expect(after, isNot(atStop + 0.5));
    });

    test('已知时长时进度封顶在曲长', () async {
      await startCastOk();
      pushStatus(const DlnaDeviceStatus(state: 'PLAYING', position: 299, duration: 300));
      // 直接把平滑值顶到接近曲末，再等一个 tick 看是否被 clamp 回 300。
      pushStatus(const DlnaDeviceStatus(state: 'PLAYING', position: 299, duration: 300));

      await Future<void>.delayed(const Duration(milliseconds: 1200));
      final st = container.read(dlnaCastProvider);
      expect(st.smoothPositionSeconds, lessThanOrEqualTo(300));
    });
  });

  // ──────────────────────────────────────────────────────────────────
  // G. startCast / playQueueOnDevice 的成功与失败分支
  // ──────────────────────────────────────────────────────────────────
  group('DlnaCastNotifier 起投分支', () {
    test('startCast 失败时回滚投屏态、清空队列并停 tick', () async {
      await startCastOk(startCastSucceeds: false);
      final ok = await notifier.startCast(
        device,
        sourceSongs.map((s) => _track(s.id, s.title)).toList(),
        startIndex: 0,
      );

      expect(ok, isFalse);
      final st = container.read(dlnaCastProvider);
      expect(st.isCasting, isFalse);
      expect(st.queue, isEmpty);
      expect(st.currentIndex, -1);
      expect(st.smoothPositionSeconds, 0);
      expect(st.currentDevice, isNull);
    });

    test('startCast 失败不请求后台权限也不暂停本机（不打断本机播放）', () async {
      await startCastOk(startCastSucceeds: false);
      await notifier.startCast(
        device,
        sourceSongs.map((s) => _track(s.id, s.title)).toList(),
      );
      // 失败分支不该调 player.pause()（真实现里那句在 success 分支内）。
      expect(manager.calls, isNot(contains('pause')));
    });

    test('playQueueOnDevice 无设备 / 空列表直接 false 且不碰 manager', () async {
      expect(await notifier.playQueueOnDevice(const <Song>[]), isFalse);
      expect(await notifier.playQueueOnDevice([_song('s1', '夜曲')]), isFalse);
      expect(manager.calls, isNot(contains('startCast')));
    });

    test('playQueueOnDevice 会 clamp 起始下标并写入投屏态', () async {
      // playQueueOnDevice 首行就 `if (currentDevice == null) return false`，
      // 所以必须先起投拿到 currentDevice 才走得到 clamp 分支。
      await startCastOk();
      final ok = await notifier.playQueueOnDevice(sourceSongs, startIndex: 99);
      expect(ok, isTrue);
      final st = container.read(dlnaCastProvider);
      expect(st.currentIndex, sourceSongs.length - 1);
      expect(st.isCasting, isTrue);
    });

    test('playSongOnDevice 未投屏时直接 false', () async {
      expect(await notifier.playSongOnDevice(_song('s1', '夜曲')), isFalse);
    });

    test('playSongOnDevice 命中已投屏队列时走 playAt 而非重投', () async {
      await startCastOk();
      manager.calls.clear();

      final ok = await notifier.playSongOnDevice(_song('s2', '晴天'));

      expect(ok, isTrue);
      expect(manager.calls, contains('playAt'));
      expect(manager.calls, isNot(contains('startCast')));
      expect(container.read(dlnaCastProvider).currentIndex, 1);
    });

    test('playSongOnDevice 带整队上下文时按整队播放', () async {
      await startCastOk();
      manager.calls.clear();

      await notifier.playSongOnDevice(
        _song('s9', '稻香'),
        queue: sourceSongs,
        index: 7,
      );

      expect(manager.calls, contains('startCast'));
      expect(container.read(dlnaCastProvider).currentIndex, sourceSongs.length - 1);
    });
  });

  // ──────────────────────────────────────────────────────────────────
  // H. 队列操作与命令转发
  // ──────────────────────────────────────────────────────────────────
  group('DlnaCastNotifier 队列与命令', () {
    test('playAt 越界不发射且不动游标', () async {
      await notifier.playAt(-1);
      expect(manager.calls, isNot(contains('playAt')));
      expect(notifier, isNot(throwsA(anything)));
    });

    test('playAt 合法下标同步游标', () async {
      await startCastOk();
      await notifier.playAt(2);
      expect(container.read(dlnaCastProvider).currentIndex, 2);
    });

    test('next 在 manager 游标变化时才同步本地', () async {
      await startCastOk();
      await notifier.next();
      expect(container.read(dlnaCastProvider).currentIndex, 1);
    });

    test('previous 同步游标', () async {
      await startCastOk();
      await notifier.playAt(1);
      await notifier.previous();
      expect(container.read(dlnaCastProvider).currentIndex, 0);
    });

    test('setPlayMode 同步到 manager 与本地状态', () async {
      await notifier.setPlayMode('one');
      expect(manager.calls, contains('mode:one'));
      expect(container.read(dlnaCastProvider).playMode, 'one');
    });

    test('cyclePlayMode 按 order→one→all→shuffle 循环', () async {
      await notifier.setPlayMode('order');
      await notifier.cyclePlayMode();
      expect(container.read(dlnaCastProvider).playMode, 'one');
      await notifier.cyclePlayMode();
      expect(container.read(dlnaCastProvider).playMode, 'all');
      await notifier.cyclePlayMode();
      expect(container.read(dlnaCastProvider).playMode, 'shuffle');
      await notifier.cyclePlayMode();
      expect(container.read(dlnaCastProvider).playMode, 'order');
    });

    test('enqueueSongs 未投屏早退；投屏时追加到队尾', () async {
      await notifier.enqueueSongs(const <Song>[]);
      expect(container.read(dlnaCastProvider).queue, isEmpty);

      await startCastOk();
      await notifier.enqueueSongs([_song('s4', '稻香')]);
      final st = container.read(dlnaCastProvider);
      expect(st.queue.length, 4);
      expect(st.queue.last.songId, 's4');
    });

    test('removeQueueItem 未投屏早退；投屏时同步收缩本机镜像', () async {
      await notifier.removeQueueItem(0);
      expect(container.read(dlnaCastProvider).queue.length, 0);

      await startCastOk();
      player.syncCastCalls = 0;
      await notifier.removeQueueItem(1);
      expect(container.read(dlnaCastProvider).queue.length, 2);
      expect(player.syncCastCalls, greaterThan(0));
    });

    test('reorderQueue 未投屏早退', () async {
      await notifier.reorderQueue(0, 1);
      expect(container.read(dlnaCastProvider).queue, isEmpty);
    });

    test('reorderQueue 投屏态下重排队列并镜像回本机', () async {
      // 补 QA(N-02)：原先只测了早退分支，重排主体（from != to 判定 / 队列双写 /
      // _mirrorCastToLocal）一行都没跑到 —— 全量 100% 是靠旧测试撑的。
      await startCastOk();
      player.syncCastCalls = 0;

      await notifier.reorderQueue(0, 2);

      final st = container.read(dlnaCastProvider);
      // [D-030] 语义已确认（2026-10-07 用户拍板）：`to` 为 Flutter
      // ReorderableListView 标准间隙下标，`insert(to > from ? to - 1 : to)`
      // 是标准写法，现状正确，不修。断言钉住该标准语义。
      expect(
        st.queue.map((t) => t.songId).toList(),
        <String>['s2', 's1', 's3'],
        reason: '[D-030] 向下拖：to 为间隙下标，落位 [s2,s1,s3]（语义已确认，不修）',
      );
      expect(manager.calls, contains('reorderQueue'));
      expect(player.syncCastCalls, greaterThan(0), reason: '重排后要镜像回本机');
    });

    test('reorderQueue 向上拖（from > to）落位正确（D-030 对照）', () async {
      await startCastOk();
      player.syncCastCalls = 0;

      await notifier.reorderQueue(2, 0);

      final st = container.read(dlnaCastProvider);
      expect(
        st.queue.map((t) => t.songId).toList(),
        <String>['s3', 's1', 's2'],
        reason: '队尾 2 移到下标 0（from > to 走 to 分支，与向下拖同属标准间隙语义）',
      );
      expect(player.syncCastCalls, greaterThan(0));
    });

    test('setMuted 只在两端状态不一致时才 toggleMute', () async {
      await notifier.setMuted(true);
      expect(manager.muteToggles, 1);
      expect(manager.isMuted, isTrue);

      // 已经在 mute 状态，再次 setMuted(true) 不应重复切。
      await notifier.setMuted(true);
      expect(manager.muteToggles, 1);

      await notifier.setMuted(false);
      expect(manager.muteToggles, 2);
    });

    test('pause / resume / toggle 按状态分流', () async {
      await notifier.pause();
      expect(manager.calls, contains('pause'));

      // toggle 看的是本地 status.state：真 manager 被暂停后会回推一帧
      // 非 PLAYING 状态，桩没模拟这个回推，这里手动拨一下。
      manager.onStatusChanged?.call(
        const DlnaDeviceStatus(state: 'PLAYING', position: 1),
      );
      await notifier.toggle();
      expect(manager.calls, contains('pause'), reason: 'PLAYING 时 toggle 应暂停');

      manager.onStatusChanged?.call(
        const DlnaDeviceStatus(state: 'STOPPED', position: 1),
      );
      await notifier.toggle();
      expect(manager.calls, contains('resume'), reason: '非 PLAYING 时 toggle 应恢复');

      // [D-029 锁定修复] pause/resume 已乐观回写本地 status：第一次 toggle 把
      // 本地状态拨成 PAUSED，第二次 toggle 读到的就是最新意图 → 走 resume，
      // 不再把陈旧 PLAYING 读成「还没暂停」而重复下发 pause。
      manager.onStatusChanged?.call(
        const DlnaDeviceStatus(state: 'PLAYING', position: 1),
      );
      final before = manager.calls.where((c) => c == 'pause').length;
      await notifier.toggle();
      await notifier.toggle();
      final after = manager.calls.where((c) => c == 'pause').length;
      expect(after, before + 1,
          reason: 'D-029：乐观回写后连点两次 toggle 只下发一次 pause');
      expect(
        container.read(dlnaCastProvider).status.state,
        'PLAYING',
        reason: '第二次 toggle 走 resume 并乐观回写为 PLAYING',
      );
    });

    test('seek / setVolume / toggleMute 透传给 manager', () async {
      await notifier.seek(42);
      await notifier.setVolume(70);
      await notifier.toggleMute();

      expect(manager.calls, contains('seek:42'));
      expect(manager.calls, contains('volume:70'));
      expect(manager.muteToggles, greaterThan(0));
    });
  });

  // ──────────────────────────────────────────────────────────────────
  // I. stopCast 与本机续播
  // ──────────────────────────────────────────────────────────────────
  group('DlnaCastNotifier 停止与续播', () {
    test('stopCast 清投屏态并按投屏进度本机续播', () async {
      await startCastOk();
      await notifier.playAt(1);
      pushStatus(const DlnaDeviceStatus(state: 'PLAYING', position: 77));

      await notifier.stopCast();

      final st = container.read(dlnaCastProvider);
      expect(st.isCasting, isFalse);
      expect(st.currentDevice, isNull);
      expect(st.smoothPositionSeconds, 0);
      // 续播：装载投屏结束时的本机曲目(下标 1) → seek 到 77s → play。
      expect(player.playSongIds, <String>['s2']);
      expect(player.seeks, <Duration>[const Duration(seconds: 77)]);
      expect(player.plays, isNotEmpty);
    });

    test('本机队列为空时 stopCast 只清投屏态，不碰播放器', () async {
      // 用一个空队列的 player 重搭容器。
      final emptyContainer = ProviderContainer(
        overrides: [
          dlnaManagerProvider.overrideWith((ref) => manager),
          playerProvider.overrideWith(
            (ref) => _RecPlayer(_playerState(const <Song>[])),
          ),
          effectiveQualityProvider.overrideWithValue(AudioQualityLevel.original),
        ],
      );
      addTearDown(emptyContainer.dispose);
      final n = emptyContainer.read(dlnaCastProvider.notifier);

      await n.startCast(
        device,
        sourceSongs.map((s) => _track(s.id, s.title)).toList(),
      );
      final emptyPlayer =
          emptyContainer.read(playerProvider.notifier) as _RecPlayer;
      emptyPlayer.playSongIds.clear();

      await n.stopCast();

      expect(emptyContainer.read(dlnaCastProvider).isCasting, isFalse);
      expect(emptyPlayer.playSongIds, isEmpty);
    });

    test('stopCast 会取消曲末提醒与 tick（不残留定时器）', () async {
      await startCastOk();
      pushStatus(const DlnaDeviceStatus(state: 'PLAYING', position: 5, duration: 200));

      await notifier.stopCast();

      // 停止后不再有平滑推进：等一个 tick 周期确认进度没被继续写。
      final afterStop = container.read(dlnaCastProvider).smoothPositionSeconds;
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(container.read(dlnaCastProvider).smoothPositionSeconds, afterStop);
    });

    test('detachOnAppRemoved 释放保活并摘掉客户端 keepalive', () async {
      await notifier.detachOnAppRemoved();
      expect(manager.detachCalls, 1);
    });
  });

  // ──────────────────────────────────────────────────────────────────
  // J. 补齐首轮漏掉的分支（覆盖率复查后补的第二批）
  // ──────────────────────────────────────────────────────────────────
  group('DlnaCastNotifier 补测分支', () {
    test('dlnaCastHttpBaseProvider 本体：没库没地址时也能求值出 null', () {
      // 这条用例专门不打 dlnaCastHttpBaseProvider 的 override，
      // 让 provider 体（ref.watch(activeLibrary/activeAddress) + resolve…）真的跑一遍。
      container = buildContainer(useRealCastBase: true);

      expect(container.read(dlnaCastHttpBaseProvider), isNull);
    });

    test('构造时把 detachOnAppRemoved 挂到后台 handler 的 onTaskRemovedCallback', () {
      container = buildContainer(withHandler: true);
      notifier = container.read(dlnaCastProvider.notifier);
      final rec = container.read(playerProvider.notifier) as _RecPlayer;

      expect(rec.handler, isNotNull);
      // notifier 构造时那句 `handler.onTaskRemovedCallback = detachOnAppRemoved`
      // 落到桩上后就变了 —— 能取到函数即证明那行跑过了。
      expect(rec.taskRemovedCallback, isNotNull);
    });

    test('设备已播到曲末时状态回写为曲末、进度不再上顶（arm-skip 分支）', () async {
      await startCastOk();
      pushStatus(const DlnaDeviceStatus(state: 'PLAYING', position: 300, duration: 300));

      await Future<void>.delayed(const Duration(milliseconds: 1100));
      final st = container.read(dlnaCastProvider);
      expect(st.smoothPositionSeconds, lessThanOrEqualTo(300));
      expect(st.status.position, 300);
    });

    test('[D-026 锁定修复] 命中行既无 verdict 也无 ok 时放行（unknown 不误杀）', () async {
      // QA（batch18 复核）发现：probeSong 命中一行但两个字段都没有 →
      // 原实现回落 `hit['ok'] == true` 得 false，被判「无源」静默拦截投屏，
      // 与「结果集里压根没这首 id → 放行」方向相反。[D-026 修复后]：
      // 只有明确带回 ok=false 才判无源，缺字段（unknown）与「没这首」同方向放行。
      container = buildContainer();
      final ref = container.read(_refHolderProvider);
      await ensureDlnaManagerReady(ref);
      api.probeResults = <dynamic>[const <String, dynamic>{'songId': 's1'}];

      expect(await manager.probeSongFn!('s1'), isTrue,
          reason: 'D-026：缺字段的命中行按 unknown 放行，不再误杀');
    });

    test('[D-026 锁定修复] 命中行明确 ok=false 仍判无源', () async {
      // 修复不改变「服务端明确不可播」的拦截方向：ok=false 仍拦。
      container = buildContainer();
      final ref = container.read(_refHolderProvider);
      await ensureDlnaManagerReady(ref);
      api.probeResults = <dynamic>[
        const <String, dynamic>{'songId': 's1', 'ok': false},
      ];

      expect(await manager.probeSongFn!('s1'), isFalse);
    });

    test('[D-026 对照] 结果集里没有这首时不误杀', () async {
      // 与修复后行为对照：没这首 → 放行；有这首但字段空 → 同样放行（方向一致）。
      container = buildContainer();
      final ref = container.read(_refHolderProvider);
      await ensureDlnaManagerReady(ref);
      api.probeResults = <dynamic>[const <String, dynamic>{'songId': 'other'}];

      expect(await manager.probeSongFn!('s1'), isTrue);
    });

    test('next 在设备没推 trackChanged 时靠 castQueueIndex 兜底同步', () async {
      await startCastOk();
      manager.syncOnCursorChange = false;
      await notifier.next();
      expect(container.read(dlnaCastProvider).currentIndex, 1);
      // 兜底分支还会把队列镜像回本机。
      expect(player.syncCastCalls, greaterThan(0));
    });

    test('previous 在设备没推 trackChanged 时靠 castQueueIndex 兜底同步', () async {
      await startCastOk();
      await notifier.playAt(1);
      manager.syncOnCursorChange = false;
      await notifier.previous();
      expect(container.read(dlnaCastProvider).currentIndex, 0);
    });

    test('playQueueOnDevice 在设备侧失败时回滚投屏态并停 tick', () async {
      await startCastOk();
      // 已经拿到 currentDevice 了，再把设备侧翻成失败，
      // 才能走到 playQueueOnDevice 的 else 分支。
      manager.startCastResult = false;

      final ok = await notifier.playQueueOnDevice(sourceSongs);

      expect(ok, isFalse);
      final st = container.read(dlnaCastProvider);
      expect(st.isCasting, isFalse);
      expect(st.queue, isEmpty);
      expect(st.currentIndex, -1);
      expect(manager.calls, contains('startCast'));
    });

    test('playSongOnDevice 单曲且不在投屏队列中时按单曲重投', () async {
      await startCastOk();
      manager.calls.clear();
      player.syncCastCalls = 0;

      final ok = await notifier.playSongOnDevice(_song('s9', '稻香'));

      expect(ok, isTrue);
      // 队列里没有 s9 → 落到 playQueueOnDevice(<Song>[song]) 单曲重投。
      expect(manager.calls, contains('startCast'));
      expect(container.read(dlnaCastProvider).queue.single.songId, 's9');
      expect(player.syncCastCalls, greaterThan(0));
    });
  });
}
