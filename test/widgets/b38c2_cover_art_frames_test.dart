// Route C 补测：`lib/widgets/cover_art_image.dart` 的剩余缺口。
//
// 覆盖点：
//   * 130-132：并发闸门放行排队封面（`grantCoverSlot` 的 mounted 分支）——
//     8 个封面只有 6 个能同时发请求，前一批失败释放槽位后排队者才被放行。
//   * 166/310/311/314：网络封面**成功出帧**分支（frame != null）——
//     释放槽位并置 `_everShownNetwork`，用 Image 语义包住真图。
//   * 328：`errorBuilder` 且 `semanticLabel != null` 时的带名失败文案。
//   * 358/361：离线缓存命中且 Image.file **成功出帧**。
//   * 364/365/367：离线缓存文件解码失败 → errorBuilder 回落占位。
//
// 跳过并报告：
//   * 163：`_scheduleSlotRelease` 的「URL 已切换」分支 —— 该回调由
//     `addPostFrameCallback` 注册并在**同一帧末**执行，而 `_lastUrl` 只在
//     build 里更新；要让二者错开需要在同一帧内 build 两次，Flutter 一帧只
//     build 一次 ⇒ 不可达。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

/// 8x8 的不透明 PNG（测试用真实位图，保证 Image.network / Image.file 能解码出帧）。
const String kTestPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAYAAADED76LAAAAEklEQVR42mM4YRP1Hx9mGBkKAOorl0GM4cQIAAAAAElFTkSuQmCC';

final Uint8List kTestPngBytes =
    Uint8List.fromList(base64Decode(kTestPngBase64));

/// 能把真实 PNG 字节吐给 NetworkImage 的 HttpClient。
class _BytesHttpClient implements HttpClient {
  _BytesHttpClient(this.bytes);
  final Uint8List bytes;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _BytesRequest(bytes);

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _BytesRequest(bytes);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _BytesRequest implements HttpClientRequest {
  _BytesRequest(this.bytes);
  final Uint8List bytes;
  @override
  Future<HttpClientResponse> close() async => _BytesResponse(bytes);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _BytesResponse extends StreamView<List<int>>
    implements HttpClientResponse {
  _BytesResponse(this.bytes)
      : super(Stream<List<int>>.fromIterable(<List<int>>[bytes]));

  final Uint8List bytes;

  @override
  int get statusCode => 200;

  @override
  int get contentLength => bytes.length;

  /// NetworkImage 会读这个枚举（不能靠 noSuchMethod 返回 null）。
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// 计数 + 一律抛错的 HttpClient：既触发 errorBuilder，又能数出真实请求次数。
class _CountingFailingHttpClient implements HttpClient {
  int requests = 0;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    requests++;
    throw const SocketException('测试用失败客户端');
  }

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    requests++;
    throw const SocketException('测试用失败客户端');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _StubOfflineCache extends OfflineCacheManager {
  _StubOfflineCache() : super(rootForTest: null);
  File? cover;

  @override
  File? coverFile(String coverKey) => cover;

  @override
  File? playlistCoverFile(String coverKey) => cover;
}

Widget _scope({
  required Widget child,
  bool offline = false,
  _StubOfflineCache? cache,
}) {
  final now = DateTime(2026, 10, 1);
  final library = MusicLibrary(
    id: 'lib-b38c2',
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
      home: Scaffold(body: Center(child: child)),
    ),
  );
}

/// 真实异步（文件 IO / 解码）在 widget test 的 fake-async 里不会自动推进，
/// 必须借 runAsync 让出真实事件循环。
Future<void> _settleAsync(WidgetTester tester, {int rounds = 10}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _settle(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

File _tempFile(String name, List<int> bytes) {
  final file = File(
    '${Directory.systemTemp.path}/b38c2-$name-${DateTime.now().microsecondsSinceEpoch}.bin',
  )..writeAsBytesSync(bytes);
  addTearDown(() {
    if (file.existsSync()) file.deleteSync();
  });
  return file;
}

void main() {
  testWidgets('网络封面成功出帧：释放槽位并渲染真图（166/310/311/314）',
      (tester) async {
    debugNetworkImageHttpClientProvider = () => _BytesHttpClient(kTestPngBytes);
    addTearDown(() => debugNetworkImageHttpClientProvider = null);

    await tester.pumpWidget(
      _scope(child: const CoverArtImage(coverArtId: 'net-ok', size: 40)),
    );
    await tester.pump();
    await _settle(tester);
    await _settleAsync(tester, rounds: 10);

    // 出帧后骨架撤下，换成带 image 语义的真图（源码 311-315 行）。
    expect(
      find.byType(MusicFlowSkeleton),
      findsNothing,
      reason: '成功出帧后不应再渲染加载骨架',
    );
    expect(find.byType(Image), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (Widget widget) =>
            widget is Semantics &&
            widget.properties.image == true &&
            widget.properties.label == '专辑封面',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    debugNetworkImageHttpClientProvider = null;
  });

  testWidgets('网络封面失败且带语义名：走带名失败文案（328）', (tester) async {
    debugNetworkImageHttpClientProvider = _CountingFailingHttpClient.new;
    addTearDown(() => debugNetworkImageHttpClientProvider = null);

    await tester.pumpWidget(
      _scope(
        child: const CoverArtImage(
          coverArtId: 'net-fail',
          size: 40,
          semanticLabel: '我的封面',
        ),
      ),
    );
    await tester.pump();
    await _settle(tester, frames: 5);
    await _settleAsync(tester, rounds: 2);

    expect(
      find.bySemanticsLabel('我的封面，封面加载失败'),
      findsOneWidget,
      reason: 'semanticLabel 非空时失败文案应带上名字（源码 328 行）',
    );
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    debugNetworkImageHttpClientProvider = null;
  });

  testWidgets('离线缓存命中且解码成功：渲染本地封面（358/361）', (tester) async {
    final cache = _StubOfflineCache()
      ..cover = _tempFile('cached', kTestPngBytes);

    await tester.pumpWidget(
      _scope(
        offline: true,
        cache: cache,
        child: const CoverArtImage(coverArtId: 'cached-ok', size: 40),
      ),
    );
    await tester.pump();
    await _settleAsync(tester, rounds: 10);

    // 本地文件成功出帧：骨架撤下，换成带 image 语义的真图（源码 358-362 行）。
    expect(find.byType(MusicFlowSkeleton), findsNothing);
    expect(find.byType(Image), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (Widget widget) =>
            widget is Semantics &&
            widget.properties.image == true &&
            widget.properties.label == '专辑封面',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    debugNetworkImageHttpClientProvider = null;
  });

  testWidgets('离线缓存文件损坏：解码失败回落占位（364/365/367）', (tester) async {
    final cache = _StubOfflineCache()
      ..cover = _tempFile('broken', <int>[0x01, 0x02, 0x03, 0x04]);

    await tester.pumpWidget(
      _scope(
        offline: true,
        cache: cache,
        child: const CoverArtImage(coverArtId: 'cached-broken', size: 40),
      ),
    );
    await tester.pump();
    await _settleAsync(tester, rounds: 10);

    expect(
      find.bySemanticsLabel('封面加载失败，自动重试中'),
      findsOneWidget,
      reason: '缓存文件无法解码时应走 Image.file 的 errorBuilder（源码 364-369 行）',
    );
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    debugNetworkImageHttpClientProvider = null;
  });

  testWidgets('闸门放行排队封面：前一批失败后排队者补位（130-132）', (tester) async {
    final http = _CountingFailingHttpClient();
    debugNetworkImageHttpClientProvider = () => http;
    addTearDown(() => debugNetworkImageHttpClientProvider = null);

    await tester.pumpWidget(
      _scope(
        child: Column(
          children: <Widget>[
            for (var i = 0; i < 8; i++)
              CoverArtImage(coverArtId: 'gate-$i', size: 40),
          ],
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    // 闸门上限 6：首批只有 6 个封面真正发起网络请求，另外 2 个排队渲染骨架。
    expect(http.requests, 6, reason: '并发闸门把在途请求封顶在 6');
    expect(find.byType(MusicFlowSkeleton), findsNWidgets(2));

    // 前一批失败 → 释放槽位 → _drain 放行排队者 → 其 grantCoverSlot 被调用。
    await _settle(tester, frames: 6);

    expect(
      http.requests,
      8,
      reason: '排队的 2 个封面应被 grantCoverSlot 放行并补发请求（源码 130-132 行）',
    );
    expect(
      find.byType(MusicFlowSkeleton),
      findsNothing,
      reason: '放行后不应再有排队骨架',
    );
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    debugNetworkImageHttpClientProvider = null;
  });
}
