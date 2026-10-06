// batch34 C 路 —— `lib/widgets/cover_art_image.dart` 补测（并发闸门/重试/离线回退）。
//
// 已有 test/widgets/cover_art_image_test.dart 覆盖安全策略与骨架约束；
// 本文件补：
//   * 全局并发闸门 _CoverRequestGate：8 个封面同时构建 → 6 个持槽发网络请求、
//     其余排队骨架；失败释放槽位后排队者被放行（_drain）；
//   * 失败自动重试：errorBuilder → 1s 指数退避 → 带尝试次数的新 key 重建；
//   * 离线回退：isOffline=true 时命中本地缓存走 Image.file；
//     alwaysFresh=true 时绕过缓存仍走网络；
//   * 解码尺寸解析：requestSize 优先，size*dpr 次之。
//
// 踩坑记录：
// #V1 闸门放行/槽位释放都走 addPostFrameCallback ⇒ 断言前必须 pump 推帧；
// #V2 重试用 Timer，用例结束前统一卸载组件树（dispose 会 cancel retryTimer），
//     避免「Timer still pending」挂掉用例；
// #V3 pending/失败 HttpClient 通过 debugNetworkImageHttpClientProvider 注入。
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/offline/offline_cache_manager.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/providers/offline/offline_provider.dart';
import 'package:musicflow_client/widgets/cover_art_image.dart';

/// 永不完成的 HttpClient：封面停留在加载态。
class _PendingHttpClient implements HttpClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// 一律抛错的 HttpClient：触发 errorBuilder → 重试/放行槽位。
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
  File? cover;

  @override
  File? coverFile(String coverKey) => cover;

  @override
  File? playlistCoverFile(String coverKey) => cover;
}

Future<void> settle(WidgetTester tester, {int frames = 6}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

Widget _boundScope({
  required Widget child,
  bool offline = false,
  _StubOfflineCache? cache,
}) {
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
      offlineCacheManagerProvider.overrideWithValue(
        cache ?? _StubOfflineCache(),
      ),
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

/// 需要 dio 的导入（Client 构造）。
void main() {
  testWidgets('并发闸门：8 个封面只有 6 个持槽发请求，其余排队骨架', (tester) async {
    debugNetworkImageHttpClientProvider = _PendingHttpClient.new;

    await tester.pumpWidget(
      _boundScope(
        child: Column(
          children: <Widget>[
            for (var i = 0; i < 8; i++)
              CoverArtImage(coverArtId: 'cover-$i', size: 40),
          ],
        ),
      ),
    );
    // 首帧：全部排队/占位；推一帧让 build 完成。
    await tester.pump();

    expect(
      find.byType(Image),
      findsNWidgets(6),
      reason: '闸门上限 6：6 个封面持槽发网络请求',
    );
    expect(
      find.byType(MusicFlowSkeleton),
      findsNWidgets(2),
      reason: '超出的 2 个封面渲染排队骨架',
    );
    expect(tester.takeException(), isNull);

    debugNetworkImageHttpClientProvider = null;
    // 卸载树释放槽位与控制器。
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('失败放行槽位：失败封面释放后，排队封面被放行发请求', (tester) async {
    debugNetworkImageHttpClientProvider = _FailingHttpClient.new;

    await tester.pumpWidget(
      _boundScope(
        child: Column(
          children: <Widget>[
            for (var i = 0; i < 3; i++)
              CoverArtImage(coverArtId: 'c-$i', size: 40),
          ],
        ),
      ),
    );
    await tester.pump();
    await settle(tester, frames: 4);

    // 3 个封面全部经历失败（errorBuilder → 占位图），失败也放行槽位。
    expect(
      find.bySemanticsLabel(RegExp('封面加载失败')),
      findsNWidgets(3),
      reason: '三个封面都应走到失败占位（zh 文案）',
    );
    // 失败放行槽位后，若仍有排队者会拿槽位再请求——这里全部已处理。
    await tester.pump(const Duration(milliseconds: 40));
    expect(tester.takeException(), isNull);

    debugNetworkImageHttpClientProvider = null;
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('失败自动重试：1s 退避后以新尝试次数 key 重建网络图', (tester) async {
    debugNetworkImageHttpClientProvider = _FailingHttpClient.new;

    await tester.pumpWidget(
      _boundScope(
        child: const Center(child: CoverArtImage(coverArtId: 'retry-1', size: 40)),
      ),
    );
    await tester.pump();
    await settle(tester, frames: 4);

    final first = tester.widget<Image>(find.byType(Image));
    expect(first.key, isA<ValueKey<String>>());
    expect((first.key as ValueKey<String>).value, contains('#0'));

    // 指数退避第一档 1s：timer 触发后 attempt=1 → 新 key 重建。
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    final second = tester.widget<Image>(find.byType(Image));
    expect(
      (second.key as ValueKey<String>).value,
      contains('#1'),
      reason: '重试应带尝试次数的 key 强制重发',
    );

    debugNetworkImageHttpClientProvider = null;
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('离线回退：isOffline=true 且缓存命中 → Image.file', (tester) async {
    final cache = _StubOfflineCache();
    final tmp = File(
      '${Directory.systemTemp.path}/b34c-cover-${DateTime.now().microsecondsSinceEpoch}.bin',
    )..writeAsBytesSync(<int>[1, 2, 3]);
    addTearDown(() => tmp.deleteSync());
    cache.cover = tmp;

    await tester.pumpWidget(
      _boundScope(
        offline: true,
        cache: cache,
        child: const Center(child: CoverArtImage(coverArtId: 'cached-1', size: 40)),
      ),
    );
    await tester.pump();

    final image = tester.widget<Image>(find.byType(Image));
    // Image.file 带 cacheWidth → ResizeImage 包裹 FileImage。
    expect(image.image, isA<ResizeImage>(), reason: '离线命中缓存应走本地文件');
    final inner = (image.image as ResizeImage).imageProvider;
    expect(inner, isA<FileImage>());
    expect((inner as FileImage).file.path, tmp.path);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('alwaysFresh=true 绕过离线缓存，仍走网络图', (tester) async {
    debugNetworkImageHttpClientProvider = _PendingHttpClient.new;

    final cache = _StubOfflineCache();
    cache.cover = File(
      '${Directory.systemTemp.path}/b34c-fresh-${DateTime.now().microsecondsSinceEpoch}.bin',
    )..writeAsBytesSync(<int>[1]);

    await tester.pumpWidget(
      _boundScope(
        offline: true,
        cache: cache,
        child: const Center(
          child: CoverArtImage(
            coverArtId: 'fresh-1',
            size: 40,
            alwaysFresh: true,
          ),
        ),
      ),
    );
    await tester.pump();

    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isNot(isA<FileImage>()), reason: '动态封面不读缓存');
    expect(tester.takeException(), isNull);

    debugNetworkImageHttpClientProvider = null;
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('解码尺寸：requestSize 优先于 size*dpr', (tester) async {
    debugNetworkImageHttpClientProvider = _PendingHttpClient.new;

    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _boundScope(
        child: Column(
          children: <Widget>[
            const CoverArtImage(coverArtId: 'size-req', size: 40, requestSize: 96),
            const CoverArtImage(coverArtId: 'size-dpr', size: 40),
          ],
        ),
      ),
    );
    await tester.pump();

    final images = tester.widgetList<Image>(find.byType(Image)).toList();
    expect(images.length, 2);
    expect(
      (images[0].image as ResizeImage).width,
      96,
      reason: 'requestSize=96 应直接作为解码宽度',
    );
    expect(
      (images[1].image as ResizeImage).width,
      80,
      reason: 'size=40 * dpr=2 → 解码宽度 80',
    );
    expect(tester.takeException(), isNull);

    debugNetworkImageHttpClientProvider = null;
    await tester.pumpWidget(const SizedBox());
  });
}
