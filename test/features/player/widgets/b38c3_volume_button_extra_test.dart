// b38c3 —— Route C 补测：VolumeButton 音量浮层剩余缺口。
//   * 125：浮层内层 opaque GestureDetector 的 onTap 空闭包（点面板内部不穿透关闭）。
//   * 315/316：竖向滑杆的 onTapDown（点按任意高度直接跳转）/ onTapUp（提交最终值）。
//
// 手法：VolumeButton 直接挂树；点按钮开浮层（插根 Overlay）→ 点百分比文字命中内层
// 空 onTap → 点滑杆中心触发 tapDown/tapUp → 点浮层外空白关闭。
// currentSong 置 null，避免 _VolumeMediaInfo 的 CoverArtImage 触发网络/定时器。
// playerProvider 用子类覆写 setVolume（TestPlayerNotifier 未覆写，noSuchMethod 对
// 非空返回 Future<void> 会抛 TypeError）。
//
// 报告为**不可达**：volume_button.dart:96（`_toggleOverlay` 里浮层已开时的
// `_removeOverlay()`）。浮层打开时其内建 `Positioned.fill` + opaque GestureDetector
// 覆盖整屏（含音量按钮），第二次点按钮的点击被该层吃掉走 `_removeOverlay`（关闭），
// 永不回到按钮的 `onPressed`；`_toggleOverlay` 的该早退分支无任何可达路径。
//
// 只写 test/，只读 lib/（产品代码零改动）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/features/player/widgets/volume_button.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

import '../test_player_notifier.dart';

class _VolPlayer extends TestPlayerNotifier {
  _VolPlayer(super.state);

  final List<double> volumes = <double>[];

  @override
  Future<void> setVolume(double volume) async {
    volumes.add(volume);
  }
}

class _StubCastPeer extends CastPeerController {
  _StubCastPeer(super.ref);
}

class _StubDlnaCast extends DlnaCastNotifier {
  _StubDlnaCast(super.ref);
}

Future<void> settle(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Finder percentText() => find.byWidgetPredicate(
      (Widget w) => w is Text && (w.data ?? '').endsWith('%'),
    );

void main() {
  testWidgets('VolumeButton：开浮层 → 内层空 onTap/滑杆点按提交（125/315/316）',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 1000);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final player = _VolPlayer(PlayerState(volume: 0.5));
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          playerProvider.overrideWith((Ref ref) => player),
          castPeerControllerProvider.overrideWith((Ref ref) {
            return _StubCastPeer(ref)..state = const CastPeerState();
          }),
          dlnaCastProvider.overrideWith((Ref ref) => _StubDlnaCast(ref)),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          theme: AppTheme.light(),
          home: const Scaffold(
            body: Align(
              alignment: Alignment.bottomRight,
              child: VolumeButton(),
            ),
          ),
        ),
      ),
    );
    await settle(tester);

    // 打开音量浮层。
    await tester.tap(find.byType(VolumeButton));
    await settle(tester);
    expect(percentText(), findsOneWidget, reason: '点音量按钮应弹出浮层');

    // 点百分比文字（非交互区）→ 命中外层 opaque 空 onTap（125）。
    await tester.tap(percentText());
    await settle(tester);
    expect(percentText(), findsOneWidget, reason: '点浮层内部不应关闭浮层');

    // 点按竖向滑杆中心 → onTapDown 跳转 + onTapUp 提交（315/316）。
    final slider = find.byKey(const Key('volume-vertical-slider'));
    expect(slider, findsOneWidget);
    await tester.tapAt(tester.getCenter(slider));
    await settle(tester);
    expect(player.volumes, isNotEmpty, reason: '点按滑杆应提交一次音量');

    // 点浮层外空白 → 关闭（清理，避免残留 Overlay）。
    await tester.tapAt(const Offset(40, 40));
    await settle(tester);
    expect(percentText(), findsNothing, reason: '点浮层外应关闭浮层');
    expect(tester.takeException(), isNull);
  });
}
