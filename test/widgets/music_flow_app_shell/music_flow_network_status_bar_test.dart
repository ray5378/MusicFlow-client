import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/core/utils/network_error_notifier.dart';
import 'package:musicflow_client/core/utils/toast_notifier.dart';
import 'package:musicflow_client/widgets/music_flow_app_shell/music_flow_network_status_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';

void main() {
  setUp(NetworkErrorNotifier.resetForTest);

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

  testWidgets(
    'recovery only releases inline space — no toast, heartbeat beacon owns it',
    (tester) async {
      final status = ValueNotifier<MusicFlowNetworkStatus>(MusicFlowNetworkStatus.offline);
      addTearDown(status.dispose);

      await _pumpStatusBar(
        tester,
        status: status,
        recoveryDisplayDuration: const Duration(milliseconds: 600),
        // 参数保留仅为兼容既有调用方：恢复连通已不再走静默窗口判断。
        startupSilentRecoveryWindow: Duration.zero,
      );
      expect(find.text('当前离线'), findsOneWidget);

      status.value = MusicFlowNetworkStatus.online;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 220));

      // 内联横幅立即释放空间，不再显示恢复横幅。
      expect(tester.getSize(_statusSlot).height, 0);
      expect(find.text('已重新连接可用线路'), findsNothing);
      // `_bannerState` 落到 hidden：横幅内容节点整体消失。
      expect(
        find.byKey(const ValueKey<String>('musicflow-network-status-offline')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('musicflow-network-status-surface')),
        findsNothing,
      );

      // 「已恢复」的提示改由顶部心跳提示（ConnectionBeacon）承担，
      // 本组件**不再**弹任何 Toast。
      expect(find.text('网络已恢复'), findsNothing);
      _expectNoToast();

      // 再推一段时间，也不该迟到地补一条。
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 220));
      expect(find.text('网络已恢复'), findsNothing);
      _expectNoToast();
    },
  );

  testWidgets('offline enter/exit and recovery never fire a network error toast', (
    tester,
  ) async {
    // 行为变更（预期内）：offline 的提示只走内联横幅，「连不上服务器」
    // 的 Toast 已删除 —— 连接状态统一由心跳提示表达。
    final status = ValueNotifier<MusicFlowNetworkStatus>(MusicFlowNetworkStatus.online);
    addTearDown(status.dispose);

    await _pumpStatusBar(tester, status: status);
    _expectNoToast();

    // online → offline（改造前正是在这一步弹 NetworkErrorNotifier）
    status.value = MusicFlowNetworkStatus.offline;
    await _settleBanner(tester);
    expect(find.text('当前离线'), findsOneWidget);
    _expectNoToast();

    // offline → weak
    status.value = MusicFlowNetworkStatus.weak;
    await _settleBanner(tester);
    expect(find.text('网络不稳定'), findsOneWidget);
    _expectNoToast();

    // weak → offline
    status.value = MusicFlowNetworkStatus.offline;
    await _settleBanner(tester);
    expect(find.text('当前离线'), findsOneWidget);
    _expectNoToast();

    // offline → online（改造前正是在这一步弹「网络已恢复」Toast）
    status.value = MusicFlowNetworkStatus.online;
    await _settleBanner(tester);
    expect(tester.getSize(_statusSlot).height, 0);
    _expectNoToast();

    // online → offline 再来一次，确认没有节流窗口掩盖第一次调用。
    status.value = MusicFlowNetworkStatus.offline;
    await _settleBanner(tester);
    expect(find.text('当前离线'), findsOneWidget);
    _expectNoToast();
  });

  testWidgets('harness self-check: a real toast IS observable here', (
    tester,
  ) async {
    // 防止上一条用例「零调用」假绿：证明本 harness 真的能看见 Toast。
    final status = ValueNotifier<MusicFlowNetworkStatus>(MusicFlowNetworkStatus.online);
    addTearDown(status.dispose);

    await _pumpStatusBar(tester, status: status);
    expect(find.byType(MusicFlowMessage), findsNothing);

    NetworkErrorNotifier.show('自检 toast');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 260));

    expect(find.byType(MusicFlowMessage), findsOneWidget);
    expect(find.text('自检 toast'), findsOneWidget);

    // 让它自行消失，避免残留计时器。
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(MusicFlowMessage), findsNothing);
  });
}

Finder get _statusSlot =>
    find.byKey(const ValueKey<String>('musicflow-network-status-slot'));

/// 断言「没有任何 Toast 被插进 Overlay」。
///
/// `NetworkErrorNotifier.show` 的唯一可观测副作用就是这条 Toast（导航器已就绪
/// 时必须立刻插入，不会滞留在 `ToastNotifier` 的 pending 里）。
void _expectNoToast() {
  expect(
    find.byType(MusicFlowMessage),
    findsNothing,
    reason: '连接状态提示已由心跳提示接管，本组件不得再弹 Toast',
  );
}

/// 内联横幅是 `AnimatedSize` + `AnimatedSwitcher`：状态切换要推两帧才稳定。
Future<void> _settleBanner(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 260));
}

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
          // 挂上根导航器关键帧：ToastNotifier 才能真的往 Overlay 里插 Toast，
          // 否则「零 Toast」断言会永远为真（假绿）。
          navigatorKey: rootNavigatorKey,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
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
