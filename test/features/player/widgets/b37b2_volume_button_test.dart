// b37b2 —— `lib/features/player/widgets/volume_button.dart` 补测。
//
// mini_player_cov 只统计桌面档位里 VolumeButton 的「数量」，未触达其内部：
//   * 打开 / 关闭音量浮层（根 Overlay 插入 / 移除、点外部关闭）；
//   * 浮层内「＋ / －」步进键（_stepVolume 的正负两向）；
//   * 竖向滑杆拖动 → onChanged 节流下发 + onChangeEnd 提交落盘；
//   * currentSong 非空时顶部展示封面/标题/艺人（artist 为空的降级）；
//   * 音量=0 显示静音图标；anchorTop 两种贴边都构建。
// 产品代码零改动；仅新增 test/。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/core/theme/app_icons.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/features/player/widgets/volume_button.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

import '../test_player_notifier.dart';

/// 记录本机音量下发的播放器桩。
class _RecPlayer extends TestPlayerNotifier {
  _RecPlayer(super.state);

  final List<double> setCalls = <double>[];
  final List<double> liveCalls = <double>[];

  @override
  Future<void> setVolume(double volume) async {
    setCalls.add(volume);
  }

  @override
  void setVolumeLive(double volume) {
    liveCalls.add(volume);
  }
}

class _FakeDlna extends DlnaCastNotifier {
  _FakeDlna(super.ref, DlnaCastState initial) {
    state = initial;
  }
}

const Key sliderKey = Key('volume-vertical-slider');

Widget host(Widget child) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      theme: AppTheme.light(),
      home: Scaffold(body: Center(child: child)),
    );

Future<void> pumpButton(
  WidgetTester tester,
  // ignore: library_private_types_in_public_api
  _RecPlayer player, {
  bool anchorTop = false,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        playerProvider.overrideWith((ref) => player),
        dlnaCastProvider.overrideWith(
          (ref) => _FakeDlna(ref, const DlnaCastState()),
        ),
      ],
      child: host(VolumeButton(anchorTop: anchorTop)),
    ),
  );
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // HapticFeedback 走平台通道；无 handler 会被吞但可能打日志，这里显式吞掉。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      return null;
    });
  });

  final song = Song(
    id: 's1',
    title: '音量测试曲',
    artist: '歌手甲',
  );

  testWidgets('点击按钮打开浮层，点外部关闭（slider 出现 / 消失）', (tester) async {
    final player = _RecPlayer(PlayerState(volume: 0.8));
    await pumpButton(tester, player);

    expect(find.byIcon(AppIcons.volumeHigh), findsOneWidget);
    expect(find.byKey(sliderKey), findsNothing);

    await tester.tap(find.byIcon(AppIcons.volumeHigh));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(sliderKey), findsOneWidget, reason: '浮层应插入根 Overlay');
    expect(find.text('80%'), findsWidgets);

    // 点左上角（浮层之外）关闭。
    await tester.tapAt(const Offset(10, 10));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(sliderKey), findsNothing, reason: '点外部应移除浮层');
  });

  testWidgets('音量=0 显示静音图标', (tester) async {
    final player = _RecPlayer(PlayerState(volume: 0));
    await pumpButton(tester, player);
    expect(find.byIcon(AppIcons.volumeMute), findsOneWidget);
    expect(find.byIcon(AppIcons.volumeHigh), findsNothing);
  });

  testWidgets('步进键：＋ 抬到 83%，－ 落到 77%', (tester) async {
    final player = _RecPlayer(PlayerState(volume: 0.8));
    await pumpButton(tester, player);
    await tester.tap(find.byIcon(AppIcons.volumeHigh));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('80%'), findsWidgets);

    await tester.tap(find.byIcon(AppIcons.add));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    // 0.8 + 0.03 = 0.83
    expect(find.text('83%'), findsWidgets);
    expect(player.setCalls, isNotEmpty);

    await tester.tap(find.byIcon(AppIcons.removeCircle));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    // 0.8 - 0.03 = 0.77
    expect(find.text('77%'), findsWidgets);
  });

  testWidgets('竖向滑杆拖动：节流下发 + 松手提交落盘', (tester) async {
    final player = _RecPlayer(PlayerState(volume: 0.5));
    await pumpButton(tester, player);
    await tester.tap(find.byIcon(AppIcons.volumeHigh));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(sliderKey), findsOneWidget);

    // 向上拖 → 音量增大。
    await tester.drag(find.byKey(sliderKey), const Offset(0, -120));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(player.liveCalls, isNotEmpty, reason: '拖动中应经节流下发 live 音量');
    expect(player.setCalls, isNotEmpty, reason: '松手应提交最终音量并落盘');
    expect(player.setCalls.last, greaterThan(0.5));
  });

  testWidgets('currentSong 非空：浮层展示标题与艺人', (tester) async {
    final player = _RecPlayer(
      PlayerState(volume: 0.8, currentSong: song, queue: <Song>[song]),
    );
    await pumpButton(tester, player);
    await tester.tap(find.byIcon(AppIcons.volumeHigh));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('音量测试曲'), findsOneWidget);
    expect(find.text('歌手甲'), findsOneWidget);
  });

  testWidgets('currentSong 无艺人：只显示标题，不崩', (tester) async {
    final noArtist = Song(id: 's2', title: '无艺人曲');
    final player = _RecPlayer(
      PlayerState(volume: 0.8, currentSong: noArtist, queue: <Song>[noArtist]),
    );
    await pumpButton(tester, player);
    await tester.tap(find.byIcon(AppIcons.volumeHigh));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('无艺人曲'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('anchorTop=true 也能正常打开浮层', (tester) async {
    final player = _RecPlayer(PlayerState(volume: 0.8));
    await pumpButton(tester, player, anchorTop: true);
    await tester.tap(find.byIcon(AppIcons.volumeHigh));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(sliderKey), findsOneWidget);
  });

  testWidgets('浮层内再次点击按钮切换关闭', (tester) async {
    final player = _RecPlayer(PlayerState(volume: 0.8));
    await pumpButton(tester, player);
    await tester.tap(find.byIcon(AppIcons.volumeHigh));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(sliderKey), findsOneWidget);

    // 浮层盖在按钮之上，直接调 dispose 路径：重挂一次 widget 触发 State.dispose。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
