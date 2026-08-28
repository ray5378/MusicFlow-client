import 'package:dio/dio.dart';
import 'dart:async';
import 'dart:io';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/utils/cover_ref_security.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/providers/api_provider.dart';
import 'package:musicflow_client/providers/library_provider.dart';
import 'package:musicflow_client/widgets/cover_art_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一个“永不结束”的模拟 HTTP 客户端：让网络封面停留在加载态，
/// 从而稳定断言 frameBuilder 中的加载骨架屏（而非直接失败回落占位）。
class _PendingNetworkHttpClient implements HttpClient {
  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _PendingNetworkRequest();
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _PendingNetworkRequest();
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _PendingNetworkRequest implements HttpClientRequest {
  @override
  final HttpHeaders headers = _EmptyHttpHeaders();
  @override
  Future<HttpClientResponse> close() async => _PendingNetworkResponse();
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// 响应体流永不结束：image 解码永远拿不齐字节，保持在加载态。
class _PendingNetworkResponse extends Stream<List<int>>
    implements HttpClientResponse {
  final StreamController<List<int>> _controller =
      StreamController<List<int>>();

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _controller.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  HttpHeaders get headers => _EmptyHttpHeaders();
  @override
  int get statusCode => 200;
  @override
  String get reasonPhrase => 'OK';
  @override
  int get contentLength => 0;
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;
  @override
  bool get persistentConnection => false;
  @override
  bool get isRedirect => false;
  @override
  List<RedirectInfo> get redirects => const <RedirectInfo>[];
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _EmptyHttpHeaders implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}
  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {}
  @override
  String? value(String name) => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// 绑定一个带 baseUrl 的客户端：可信直链封面需经服务端代理,
/// 未绑库时 getCoverArtUrl 返回空、组件退回占位符。
Widget scopeWithBoundClient({required Widget child}) {
  final now = DateTime(2026, 7, 15);
  final library = MusicLibrary(
    id: 'library-cover',
    name: 'Cover Library',
    createdAt: now,
    updatedAt: now,
  );
  final client = SubsonicApiClient(
    dio: Dio(BaseOptions(baseUrl: 'https://music.example.test')),
  )..setLibrary(library);
  return ProviderScope(
    overrides: <Override>[
      activeLibraryProvider.overrideWithValue(library),
      subsonicApiClientProvider.overrideWithValue(client),
    ],
    child: child,
  );
}

void main() {
  Widget buildSubject(String? coverArtId) {
    return ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: Center(child: CoverArtImage(coverArtId: coverArtId, size: 48)),
        ),
      ),
    );
  }

  testWidgets('blocks raw file paths and raw external urls', (tester) async {
    await tester.pumpWidget(buildSubject('file:///sdcard/secret.jpg'));
    await tester.pump();

    expect(find.byType(Image), findsNothing);
    expect(find.byIcon(AppIcons.music), findsOneWidget);
    expect(find.bySemanticsLabel('暂无封面'), findsOneWidget);

    await tester.pumpWidget(buildSubject('https://evil.example/cover.jpg'));
    await tester.pump();

    expect(find.byType(Image), findsNothing);
    expect(find.byIcon(AppIcons.music), findsOneWidget);
  });

  testWidgets('allows trusted direct cover url refs', (tester) async {
    debugNetworkImageHttpClientProvider = _PendingNetworkHttpClient.new;
    await tester.pumpWidget(
      scopeWithBoundClient(
        child: buildSubject(
          toTrustedCoverUrlRef('https://img.example.com/cover.jpg?size=800'),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(Image), findsOneWidget);
    expect(find.byType(MusicFlowSkeleton), findsOneWidget);
    expect(find.bySemanticsLabel('专辑封面'), findsOneWidget);
    debugNetworkImageHttpClientProvider = null;
  });

  testWidgets('uses a caller-provided accessible cover label', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: CoverArtImage(
              coverArtId: null,
              size: 48,
              semanticLabel: '测试歌曲封面',
            ),
          ),
        ),
      ),
    );

    expect(find.bySemanticsLabel('测试歌曲封面'), findsOneWidget);
  });

  testWidgets('size-null loading skeleton stays finite in loose constraints', (
    tester,
  ) async {
    debugNetworkImageHttpClientProvider = _PendingNetworkHttpClient.new;
    Widget subject({
      required Widget Function(Widget) layout,
      required String id,
    }) {
      return scopeWithBoundClient(
        child: ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: layout(
                CoverArtImage(
                  coverArtId: toTrustedCoverUrlRef(
                    'https://img.example.com/$id.jpg',
                  ),
                  semanticLabel: '$id 封面',
                ),
              ),
            ),
          ),
        ),
      );
    }

    await tester.pumpWidget(
      subject(
        id: 'bounded',
        layout: (child) =>
            Center(child: SizedBox(width: 120, height: 80, child: child)),
      ),
    );
    await tester.pump();

    expect(tester.getSize(find.byType(MusicFlowSkeleton)), const Size(120, 80));
    expect(find.bySemanticsLabel('bounded 封面'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(
      subject(
        id: 'unbounded',
        layout: (child) => UnconstrainedBox(child: child),
      ),
    );
    await tester.pump();

    expect(tester.getSize(find.byType(MusicFlowSkeleton)), const Size(48, 48));
    expect(find.bySemanticsLabel('unbounded 封面'), findsOneWidget);
    expect(tester.takeException(), isNull);
    debugNetworkImageHttpClientProvider = null;
  });
}
