// b38c3 —— Route C 补测：remote_control_section.dart 告警条「离线」分支（143）。
//   * 143：_alertBar 的 `alert == unreachable ? unreachable文案 : offline文案` 的 else
//     —— 需 isOfflineProvider=false 且投屏控制器 offline=true（RemoteControlAlert.offline）。
//
// 手法：直接挂 RemoteControlSection；peers/targets 打桩为空（走空态，避免拉起
// RemoteControlBody 的整条播放链路），cast 控制器 offline=true 触发离线告警条。
//
// 报告为**死代码/未使用回调**（未强行凑数）：
//   * remote_control_section.dart:109-111 是传给 RemoteControlVolumePanel 的 `onClose`
//     闭包。RemoteControlVolumePanel 内部只存 `final VoidCallback? onClose;`（全仓
//     grep 仅此一处声明 + `this.onClose` 形参），**从不调用**它；面板关闭实际由
//     外层 opaque GestureDetector / 音量按钮 toggle 完成。该参数在接线端属未使用。
//
// 只写 test/，只读 lib/（产品代码零改动）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/peer.dart';
import 'package:musicflow_client/features/discover/widgets/remote_control_section.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/offline/offline_provider.dart';
import 'package:musicflow_client/providers/ui/home_remote_control_provider.dart';

class _StubCastPeer extends CastPeerController {
  _StubCastPeer(super.ref);
}

late AppLocalizations loc;

Future<void> settle(WidgetTester tester, {int frames = 10}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  testWidgets('RemoteControlSection：投屏端离线 → 离线告警条（143）', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 1200);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          remoteControlPeersProvider.overrideWith(
            (Ref ref) async => <PeerInfo>[],
          ),
          remoteControlTargetsProvider
              .overrideWith((Ref ref) => <PeerInfo>[]),
          isOfflineProvider.overrideWithValue(false),
          castPeerControllerProvider.overrideWith((Ref ref) {
            return _StubCastPeer(ref)
              ..state = const CastPeerState(offline: true);
          }),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          theme: AppTheme.light(),
          builder: (context, child) {
            loc = AppLocalizations.of(context);
            return child!;
          },
          home: const Scaffold(body: RemoteControlSection()),
        ),
      ),
    );
    await settle(tester);

    expect(find.text(loc.home_remote_offline), findsOneWidget,
        reason: '非 unreachable 的告警应走离线文案分支');
    expect(find.text(loc.home_remote_unreachable), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
