import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:musicflow_client/core/design/echo_design.dart';
import 'package:musicflow_client/core/utils/cover_ref_security.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/sources/subsonic_api_client.dart';
import 'package:musicflow_client/providers/api_provider.dart';
import 'package:musicflow_client/providers/library_provider.dart';
import 'package:musicflow_client/widgets/cover_art_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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

    expect(find.byType(CachedNetworkImage), findsNothing);
    expect(find.byIcon(AppIcons.music), findsOneWidget);
    expect(find.bySemanticsLabel('暂无封面'), findsOneWidget);

    await tester.pumpWidget(buildSubject('https://evil.example/cover.jpg'));
    await tester.pump();

    expect(find.byType(CachedNetworkImage), findsNothing);
    expect(find.byIcon(AppIcons.music), findsOneWidget);
  });

  testWidgets('allows trusted direct cover url refs', (tester) async {
    await tester.pumpWidget(
      scopeWithBoundClient(
        child: buildSubject(
          toTrustedCoverUrlRef('https://img.example.com/cover.jpg?size=800'),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(CachedNetworkImage), findsOneWidget);
    expect(find.byType(EchoSkeleton), findsOneWidget);
    expect(find.bySemanticsLabel('专辑封面'), findsOneWidget);
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

    expect(tester.getSize(find.byType(EchoSkeleton)), const Size(120, 80));
    expect(find.bySemanticsLabel('bounded 封面'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(
      subject(
        id: 'unbounded',
        layout: (child) => UnconstrainedBox(child: child),
      ),
    );
    await tester.pump();

    expect(tester.getSize(find.byType(EchoSkeleton)), const Size(48, 48));
    expect(find.bySemanticsLabel('unbounded 封面'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
