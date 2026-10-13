// batch50 H 路 —— `lib/core/network/cover_pressure_observer.dart` +
// `lib/widgets/cover_art_image.dart` 背压消费（§5.2 / ADR-4）补测。
//
// 覆盖三组：
//   A. 观测器纯逻辑：响应头解析（饱和标记 / Retry-After / 非法值 / 大小写）、
//      封面 URL 判定、信号 TTL 过期与 resetForTest；
//   B. 闸门反馈（widget）：饱和窗口内 CoverArtImage 全部骨架占位、零网络
//      请求；信号过期重建后恢复 4 并发；失败重试延时取
//      max(指数退避, Retry-After)；
//   C. loopback 端到端：真 HttpServer 回 200 + 响应头，经安装后的
//      HttpOverrides 全局包装发起真实请求，验证信号被记录（仅封面 URL）。
//
// 测试缝说明：信号源（观测器读响应头）与消费端（闸门/退避）解耦——B 组
// 经 CoverPressureObserver.recordHeaders 直接注入信号（widget 环境下
// NetworkImage 走 debugNetworkImageHttpClientProvider 注入的 client，
// 不经过全局包装）；C 组验证观测器本身的真实链路。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/network/cover_pressure_observer.dart';
import 'package:musicflow_client/core/offline/offline_cache_manager.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/providers/offline/offline_provider.dart';
import 'package:musicflow_client/widgets/cover_art_image.dart';

/// 计数 + 永不完成型 HttpClient：记录 getUrl/openUrl 调用次数，请求永远
/// 挂起（Image 停留 loading、槽位不释放），用于冻结闸门状态做确定性断言
/// （对照 b34c 的 _PendingHttpClient，叠加调用计数）。
class _PendingCountingHttpClient implements HttpClient {
  int getUrlCalls = 0;
  int openUrlCalls = 0;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    getUrlCalls++;
    return Completer<HttpClientRequest>().future;
  }

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    openUrlCalls++;
    return Completer<HttpClientRequest>().future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// 一律抛错的 HttpClient（触发 errorBuilder → 重试路径）。
class _FailingHttpClient implements HttpClient {
  @override
  Future<HttpClientRequest> getUrl(Uri url) async =>
      throw const SocketException('测试用失败客户端');

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      throw const SocketException('测试用失败客户端');

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// 只 override coverFile/playlistCoverFile 的缓存桩。
class _StubOfflineCache extends OfflineCacheManager {
  _StubOfflineCache() : super(rootForTest: null);

  @override
  File? coverFile(String coverKey) => null;

  @override
  File? playlistCoverFile(String coverKey) => null;
}

Widget _boundScope({required Widget child, bool offline = false}) {
  final now = DateTime(2026, 10, 1);
  final library = MusicLibrary(
    id: 'lib-cover',
    name: '封面测试库',
    createdAt: now,
    updatedAt: now,
  );
  final client = SubsonicApiClient(
    dio: Dio(BaseOptions(baseUrl: 'https://music.example.test')),
  )..setLibrary(library);
  return ProviderScope(
    overrides: <Override>[
      subsonicApiClientProvider.overrideWithValue(client),
      activeLibraryProvider.overrideWithValue(library),
      activeAddressProvider.overrideWith(
        (ref) => ServerAddress(
          id: 'addr-ok',
          libraryId: library.id,
          label: '测试地址',
          url: 'https://music.example.test',
          priority: 0,
          status: ServerAddressStatus.ok,
        ),
      ),
      isOfflineProvider.overrideWithValue(offline),
      offlineCacheManagerProvider.overrideWithValue(_StubOfflineCache()),
      offlineCacheReadyProvider.overrideWith((ref) async {}),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: Scaffold(body: child),
    ),
  );
}

Future<void> settle(WidgetTester tester, {int frames = 6}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

void main() {
  // ------------------------------------------------------------------
  // A. 观测器纯逻辑
  // ------------------------------------------------------------------
  group('A. parseCoverPressureHeaders 纯逻辑', () {
    test('无头 / 空 map → none', () {
      expect(parseCoverPressureHeaders(const {}), CoverPressureSignal.none);
      expect(
        parseCoverPressureHeaders(const {'content-type': 'image/png'}),
        CoverPressureSignal.none,
      );
    });

    test('饱和标记：1 → saturated；0 / 空串 → 不饱和', () {
      final on = parseCoverPressureHeaders(
        const {'x-musicflow-cover-saturated': '1'},
      );
      expect(on.saturated, isTrue);
      expect(on.retryAfterSeconds, 0);

      final off = parseCoverPressureHeaders(
        const {'x-musicflow-cover-saturated': '0'},
      );
      expect(off, CoverPressureSignal.none);

      final empty = parseCoverPressureHeaders(
        const {'x-musicflow-cover-saturated': ''},
      );
      expect(empty, CoverPressureSignal.none);
    });

    test('Retry-After：合法秒数 → 透传；非法 / 非正 → 0', () {
      final one = parseCoverPressureHeaders(const {'retry-after': '1'});
      expect(one.saturated, isFalse);
      expect(one.retryAfterSeconds, 1);

      final five = parseCoverPressureHeaders(const {'retry-after': '5'});
      expect(five.retryAfterSeconds, 5);

      expect(
        parseCoverPressureHeaders(const {'retry-after': 'abc'})
            .retryAfterSeconds,
        0,
      );
      expect(
        parseCoverPressureHeaders(const {'retry-after': '0'}).retryAfterSeconds,
        0,
      );
      expect(
        parseCoverPressureHeaders(const {'retry-after': '-3'}).retryAfterSeconds,
        0,
      );
    });

    test('两头齐备：saturated + retryAfterSeconds 同时为真', () {
      final signal = parseCoverPressureHeaders(const {
        'x-musicflow-cover-saturated': '1',
        'retry-after': '2',
      });
      expect(signal.saturated, isTrue);
      expect(signal.retryAfterSeconds, 2);
    });

    test('key 大小写不敏感（服务端头名可能任意大小写）', () {
      final signal = parseCoverPressureHeaders(const {
        'X-MusicFlow-Cover-Saturated': '1',
        'Retry-After': '3',
      });
      expect(signal.saturated, isTrue);
      expect(signal.retryAfterSeconds, 3);
    });

    test('CoverPressureSignal 相等性（== / hashCode）', () {
      const a = CoverPressureSignal(saturated: true, retryAfterSeconds: 1);
      const b = CoverPressureSignal(saturated: true, retryAfterSeconds: 1);
      const c = CoverPressureSignal(saturated: false, retryAfterSeconds: 1);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });

  group('A2. isCoverArtUrl 判定', () {
    test('命中 /rest/getCoverArt（含 query 与任意大小写）', () {
      expect(
        isCoverArtUrl(
          Uri.parse('https://music.example.test/rest/getCoverArt?id=x&size=500'),
        ),
        isTrue,
      );
      expect(isCoverArtUrl(Uri.parse('https://h/rest/getCoverArt')), isTrue);
      expect(
        isCoverArtUrl(Uri.parse('https://h/REST/GetCoverArt?id=x')),
        isTrue,
      );
    });

    test('非封面路径不命中', () {
      expect(isCoverArtUrl(Uri.parse('https://h/rest/stream?id=1')), isFalse);
      expect(
        isCoverArtUrl(Uri.parse('https://h/rest/getCoverArts?id=1')),
        isFalse,
        reason: '后缀必须恰好是 /getcoverart，getCoverArts 不算',
      );
      expect(isCoverArtUrl(Uri.parse('https://h/rest/getCoverArtExtra')), isFalse);
    });
  });

  group('A3. CoverPressureObserver 状态机', () {
    setUp(CoverPressureObserver.resetForTest);
    tearDown(CoverPressureObserver.resetForTest);

    test('recordHeaders 记录 / resetForTest 清空', () {
      expect(CoverPressureObserver.currentSignal(), CoverPressureSignal.none);
      expect(CoverPressureObserver.isSaturated, isFalse);

      CoverPressureObserver.recordHeaders(const {
        'x-musicflow-cover-saturated': '1',
        'retry-after': '1',
      });
      expect(CoverPressureObserver.isSaturated, isTrue);
      expect(
        CoverPressureObserver.currentSignal().retryAfterSeconds,
        1,
      );
      expect(CoverPressureObserver.signalRemainingMs(), greaterThan(0));

      CoverPressureObserver.resetForTest();
      expect(CoverPressureObserver.currentSignal(), CoverPressureSignal.none);
      expect(CoverPressureObserver.signalRemainingMs(), 0);
    });

    test('none 信号不覆盖既有信号', () {
      CoverPressureObserver.recordHeaders(const {
        'x-musicflow-cover-saturated': '1',
      });
      // 后续一个不带背压头的响应不应把窗口里的饱和信号清掉。
      CoverPressureObserver.recordHeaders(const {'content-type': 'image/png'});
      expect(CoverPressureObserver.isSaturated, isTrue);
    });

    test('TTL 30s 过期：注入 now 跨越有效期 → none', () {
      CoverPressureObserver.recordHeaders(const {
        'x-musicflow-cover-saturated': '1',
      });
      final recordedAt = DateTime.now();
      final beforeExpiry = recordedAt.add(const Duration(seconds: 29));
      final afterExpiry = recordedAt.add(const Duration(seconds: 31));
      expect(
        CoverPressureObserver.currentSignal(now: beforeExpiry).saturated,
        isTrue,
      );
      expect(
        CoverPressureObserver.currentSignal(now: afterExpiry),
        CoverPressureSignal.none,
      );
      expect(
        CoverPressureObserver.signalRemainingMs(now: afterExpiry),
        0,
      );
    });
  });

  // ------------------------------------------------------------------
  // B. 闸门反馈（widget）
  // ------------------------------------------------------------------
  group('B. 饱和窗口的闸门消费（widget）', () {
    setUp(() {
      CoverPressureObserver.resetForTest();
      // 兜底：用例中途失败也不把注入口残留给后续用例（原先靠各用例末尾
      // 手动置 null,失败早退时会泄漏）。
      addTearDown(() => debugNetworkImageHttpClientProvider = null);
    });
    tearDown(CoverPressureObserver.resetForTest);

    testWidgets('饱和窗口内：8 个封面全部骨架占位、零网络请求', (tester) async {
      final client = _PendingCountingHttpClient();
      debugNetworkImageHttpClientProvider = () => client;

      // 注入饱和信号（模拟观测器刚收到服务端饱和头）。
      CoverPressureObserver.recordHeaders(const {
        'x-musicflow-cover-saturated': '1',
        'retry-after': '1',
      });

      await tester.pumpWidget(
        _boundScope(
          child: Column(
            children: <Widget>[
              for (var i = 0; i < 8; i++)
                CoverArtImage(coverArtId: 'sat-$i', size: 40),
            ],
          ),
        ),
      );
      await tester.pump();
      await settle(tester, frames: 4);

      expect(
        find.byType(MusicFlowSkeleton),
        findsNWidgets(8),
        reason: '饱和窗口内不发任何封面请求，全部骨架占位',
      );
      expect(find.byType(Image), findsNothing);
      expect(
        client.getUrlCalls + client.openUrlCalls,
        0,
        reason: '饱和窗口内零请求：不往已饱和的服务端渲染队列堆积',
      );
      expect(tester.takeException(), isNull);

      debugNetworkImageHttpClientProvider = null;
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('信号过期重建：恢复 4 并发持槽发请求', (tester) async {
      final client = _PendingCountingHttpClient();
      debugNetworkImageHttpClientProvider = () => client;

      CoverPressureObserver.recordHeaders(const {
        'x-musicflow-cover-saturated': '1',
      });

      await tester.pumpWidget(
        _boundScope(
          child: Column(
            children: <Widget>[
              for (var i = 0; i < 8; i++)
                CoverArtImage(coverArtId: 'drain-$i', size: 40),
            ],
          ),
        ),
      );
      await tester.pump();
      await settle(tester, frames: 4);
      expect(find.byType(Image), findsNothing);

      // 信号过期（reset 模拟 TTL 到期）→ 观察定时器到期重建 → 恢复闸门。
      // 观察定时器按信号剩余时长一次性到期（此处无 Retry-After ⇒ 兜底 TTL
      // 30s）；reset 只清信号、不改已排定的 Timer,故需推进 >=30s 让它触发。
      CoverPressureObserver.resetForTest();
      await tester.pump(const Duration(seconds: 31));
      await settle(tester, frames: 4);

      expect(
        find.byType(Image),
        findsNWidgets(4),
        reason: '窗口结束 drain：恢复闸门上限 4 并发（ADR-4 对齐服务端渲染并发）',
      );
      expect(
        client.getUrlCalls + client.openUrlCalls,
        4,
        reason: '恰好 4 个封面持槽发起请求，其余仍排队骨架',
      );
      expect(tester.takeException(), isNull);

      debugNetworkImageHttpClientProvider = null;
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('失败重试延时取 max(指数退避, Retry-After)', (tester) async {
      debugNetworkImageHttpClientProvider = _FailingHttpClient.new;

      // 真实场景：观测器在窗口内收到过服务端 Retry-After=3（未标饱和，
      // 闸门不拦截请求）；请求发出后加载失败 → errorBuilder 安排重试时
      // 读到信号 ⇒ 退避 = max(1s 指数, 3s Retry-After) = 3s。
      CoverPressureObserver.recordHeaders(const {'retry-after': '3'});

      await tester.pumpWidget(
        _boundScope(
          child: const Center(
            child: CoverArtImage(coverArtId: 'backoff-1', size: 40),
          ),
        ),
      );
      await tester.pump();
      await settle(tester, frames: 4);

      final first = tester.widget<Image>(find.byType(Image));
      expect((first.key as ValueKey<String>).value, contains('#0'));

      // 1s（指数退避第一档）：Retry-After=3s 未到，不应重建。
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(
        (tester.widget<Image>(find.byType(Image)).key as ValueKey<String>).value,
        contains('#0'),
        reason: 'Retry-After(3s) > 指数退避(1s)：1s 时点不得重试',
      );

      // 推到 3s：max(1s, 3s) 到期，attempt=1 换 key 重建。
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(
        (tester.widget<Image>(find.byType(Image)).key as ValueKey<String>).value,
        contains('#1'),
        reason: '重试延时 = max(指数退避, Retry-After) = 3s',
      );

      debugNetworkImageHttpClientProvider = null;
      await tester.pumpWidget(const SizedBox());
    });
  });

  // ------------------------------------------------------------------
  // C. loopback 端到端（观测器真实链路）
  // ------------------------------------------------------------------
  group('C. loopback 端到端：真响应头 → 信号', () {
    late HttpServer server;
    late Uri coverUri;
    late Uri streamUri;
    late HttpOverrides? savedOverrides;

    setUp(() async {
      savedOverrides = HttpOverrides.current;
      // 本组是**真 loopback 端到端**：必须让 HttpClient() 走真实实现,故先撤下
      // flutter_test 的全局桩（它把所有请求变成 400）,再安装观测器
      // （观测器 C4 起会保留并委派 HttpOverrides.current）。
      HttpOverrides.global = null;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      coverUri = Uri.parse(
        'http://127.0.0.1:${server.port}/rest/getCoverArt?id=cov-1&size=500',
      );
      streamUri = Uri.parse(
        'http://127.0.0.1:${server.port}/rest/stream?id=s-1',
      );
      server.listen((request) async {
        if (request.uri.path.endsWith('/getCoverArt')) {
          request.response.headers.add(
            'X-MusicFlow-Cover-Saturated',
            '1',
          );
          request.response.headers.add('Retry-After', '1');
        }
        request.response.write(const AsciiEncoder().convert('PNGDATA'));
        await request.response.close();
      });
      CoverPressureObserver.resetForTest();
      CoverPressureObserver.install();
    });

    tearDown(() async {
      HttpOverrides.global = savedOverrides;
      CoverPressureObserver.resetForTest();
      await server.close(force: true);
    });

    test('封面 URL：响应头被记录为饱和信号', () async {
      final client = HttpClient();
      final request = await client.getUrl(coverUri);
      final response = await request.close();
      await response.drain<void>();
      client.close(force: true);

      final signal = CoverPressureObserver.currentSignal();
      expect(signal.saturated, isTrue);
      expect(signal.retryAfterSeconds, 1);
    });

    test('非封面 URL：不记录信号（观测零行为改变其他流量）', () async {
      final client = HttpClient();
      final request = await client.getUrl(streamUri);
      final response = await request.close();
      await response.drain<void>();
      client.close(force: true);

      expect(
        CoverPressureObserver.currentSignal(),
        CoverPressureSignal.none,
        reason: '非封面流量只透传，不记录任何信号',
      );
    });
  });
}
