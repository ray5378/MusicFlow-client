import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/widgets/music_flow_app_shell/music_flow_network_status_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('online state keeps the global status slot hidden', (
    tester,
  ) async {
    final status = ValueNotifier<MusicFlowNetworkStatus>(MusicFlowNetworkStatus.online);
    addTearDown(status.dispose);

    await _pumpStatusBar(tester, status: status);

    expect(find.text('当前离线'), findsNothing);
    expect(find.text('网络不稳定'), findsNothing);
    expect(find.text('网络已恢复'), findsNothing);
    expect(tester.getSize(_statusSlot).height, 0);
  });

  testWidgets('offline state explains that existing content remains usable', (
    tester,
  ) async {
    final status = ValueNotifier<MusicFlowNetworkStatus>(MusicFlowNetworkStatus.offline);
    addTearDown(status.dispose);

    await _pumpStatusBar(tester, status: status, textScale: 2);

    expect(find.text('当前离线'), findsOneWidget);
    expect(find.text('已加载内容和离线歌曲仍可使用，在线操作将在联网后恢复'), findsOneWidget);
    expect(tester.getSize(_statusSlot).height, greaterThan(0));
    final statusSurface = find.byKey(
      const ValueKey<String>('musicflow-network-status-surface'),
    );
    final surfaceContext = tester.element(statusSurface);
    final surfaceSize = tester.getSize(statusSurface);
    final slotSize = tester.getSize(_statusSlot);
    expect(
      surfaceSize.width,
      slotSize.width - surfaceContext.musicFlowSpacing.sm * 2,
    );
    expect(surfaceSize.height, slotSize.height);
    expect(
      tester.widget<MusicFlowSurface>(statusSurface).borderRadius,
      surfaceContext.musicFlowRadii.surface,
    );
    expect(find.byType(MaterialBanner), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('weak state reports retry without replacing cached content', (
    tester,
  ) async {
    final status = ValueNotifier<MusicFlowNetworkStatus>(MusicFlowNetworkStatus.weak);
    addTearDown(status.dispose);

    await _pumpStatusBar(tester, status: status);

    expect(find.text('网络不稳定'), findsOneWidget);
    expect(find.textContaining('正在重试可用线路'), findsOneWidget);
    expect(find.textContaining('已加载内容和离线歌曲仍可使用'), findsOneWidget);
  });

  testWidgets('recovery releases inline space and shows a top-right toast instead', (
    tester,
  ) async {
    final status = ValueNotifier<MusicFlowNetworkStatus>(MusicFlowNetworkStatus.offline);
    addTearDown(status.dispose);

    await _pumpStatusBar(
      tester,
      status: status,
      recoveryDisplayDuration: const Duration(milliseconds: 600),
      // 测试时钟无法推进 DateTime.now 的真实时间,关闭启动静默窗口以
      // 验证「网络已恢复」toast 路径(生产默认 30 秒静默)。
      startupSilentRecoveryWindow: Duration.zero,
    );
    expect(find.text('当前离线'), findsOneWidget);

    status.value = MusicFlowNetworkStatus.online;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));

    // 内联横幅立即释放空间，不再显示恢复横幅。
    expect(tester.getSize(_statusSlot).height, 0);
    expect(find.text('已重新连接可用线路'), findsNothing);
    // 网络恢复改为右上角 Toast 通知。
    expect(find.text('网络已恢复'), findsOneWidget);

    // Toast 自动消失。
    await tester.pump(const Duration(milliseconds: 380));
    await tester.pump(const Duration(milliseconds: 220));

    expect(find.text('网络已恢复'), findsNothing);
  });
}

Finder get _statusSlot =>
    find.byKey(const ValueKey<String>('musicflow-network-status-slot'));

Future<void> _pumpStatusBar(
  WidgetTester tester, {
  required ValueNotifier<MusicFlowNetworkStatus> status,
  Duration recoveryDisplayDuration = const Duration(seconds: 3),
  Duration startupSilentRecoveryWindow = const Duration(seconds: 30),
  double textScale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 800);
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: MediaQuery(
        data: MediaQueryData(
          size: const Size(390, 800),
          textScaler: TextScaler.linear(textScale),
        ),
        child: Align(
          alignment: Alignment.bottomCenter,
          child: ValueListenableBuilder<MusicFlowNetworkStatus>(
            valueListenable: status,
            builder: (context, value, child) {
              return MusicFlowNetworkStatusBar(
                status: value,
                recoveryDisplayDuration: recoveryDisplayDuration,
                startupSilentRecoveryWindow: startupSilentRecoveryWindow,
              );
            },
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
