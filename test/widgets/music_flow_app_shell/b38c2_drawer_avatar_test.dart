// Route C 补测：`lib/widgets/music_flow_app_shell/music_flow_drawer.dart`
//
// 覆盖点（_Avatar）：
//   * 296/297：identity header 带 avatarUrl 时走 Image.network；
//   * 300：网络头像加载失败 → errorBuilder 回落到默认头像图标。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/widgets/music_flow_app_shell/music_flow_drawer.dart';

/// 一律抛错的 HttpClient：强制 Image.network 走 errorBuilder。
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

Widget _header({String? avatarUrl}) => MaterialApp(
      theme: AppTheme.light(),
      locale: const Locale('zh', 'CN'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Scaffold(
        body: SizedBox(
          width: 360,
          child: MusicFlowDrawerIdentityHeader(
            username: 'tester',
            libraryName: '测试音乐库',
            addressLabel: 'https://music.example.test',
            connectionState: MusicFlowDrawerConnectionState.connected,
            showingLibraries: false,
            onToggleLibraries: () {},
            avatarUrl: avatarUrl,
          ),
        ),
      ),
    );

void main() {
  testWidgets('无头像时直接回落默认头像', (tester) async {
    await tester.pumpWidget(_header());
    await tester.pump();

    expect(find.byIcon(AppIcons.profile), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('有头像时走 Image.network，加载失败回落到默认头像（296/297/300）',
      (tester) async {
    debugNetworkImageHttpClientProvider = _FailingHttpClient.new;
    addTearDown(() => debugNetworkImageHttpClientProvider = null);

    await tester.pumpWidget(
      _header(avatarUrl: 'https://music.example.test/avatar.png'),
    );
    await tester.pump();

    // 首帧：Image.network 已挂上（源码 296/297 行）。
    expect(find.byType(Image), findsOneWidget);
    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isA<NetworkImage>());
    expect((image.image as NetworkImage).url,
        'https://music.example.test/avatar.png');

    // 加载失败 → errorBuilder 回落默认头像（源码 300 行）。
    // avatarUrl 非空时 fallback 只可能由 errorBuilder 产出，因此「出现回落头像」
    // 本身就证明 300 行被执行。
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }

    expect(
      find.byIcon(AppIcons.profile),
      findsOneWidget,
      reason: '加载失败后应回落默认头像（Image 节点仍在，但内容被替换）',
    );
    expect(tester.takeException(), isNull);

    // 还原 painting 调试变量（否则用例末尾的 invariant 校验会报「被修改」）。
    debugNetworkImageHttpClientProvider = null;
  });
}
