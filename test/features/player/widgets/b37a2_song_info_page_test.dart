// batch37-A2 —— `lib/features/player/widgets/song_info_page.dart` 补测。
//
// 该页是纯展示 widget：三组信息（歌曲/音频/文件）的每一行都由一串**私有格式化
// 辅助方法**产出，整行空时隐藏。既有测试都只经 FullPlayerPage 的 PageView 顺带
// 渲染（只走「字段齐全」那一条组合），因此下面这些分支一直 0 命中：
//   128 `_nonEmpty(null)` 的空值侧；
//   136 有 suffix → 大写返回；138/139 无 suffix 但有 contentType → 大写返回；
//   147/148/149 码率回退链：>=10000 视作 bps 折算 kbps，否则按原值；
//   158 采样率非整数 kHz → 保留 1 位小数（整数 kHz 走另一支）；
//   167/169/170/171 声道：null/≤0 隐藏、单声道、立体声、N 声道；
//   176/177/178 文件大小：null/≤0 隐藏、否则格式化 MB。
//
// 只读渲染，不点「歌曲操作」（那会打开真实 bottom sheet）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/design/components/music_flow_anchor.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/song.dart';
import 'package:musicflow_client/features/player/widgets/song_info_page.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

import '../test_player_notifier.dart';

AppLocalizations? loc;

Song _rich({
  required String id,
  String? suffix,
  String? contentType,
  int? bitRate,
  int? samplingRate,
  int? bitDepth,
  int? channelCount,
  int? size,
  String? genre,
  int? discNumber,
  String? path,
  int? duration,
}) =>
    Song(
      id: id,
      title: '信息曲',
      artist: '歌手',
      album: '专辑',
      suffix: suffix,
      contentType: contentType,
      bitRate: bitRate,
      samplingRate: samplingRate,
      bitDepth: bitDepth,
      channelCount: channelCount,
      size: size,
      genre: genre,
      discNumber: discNumber,
      path: path,
      duration: duration,
    );

Future<void> pumpInfo(
  WidgetTester tester,
  Song song, {
  int currentBitRateKbps = 0,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(900, 1600);
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        playerProvider.overrideWith(
          (ref) => TestPlayerNotifier(
            PlayerState(
              currentSong: song,
              currentBitRateKbps: currentBitRateKbps,
            ),
          ),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.dark(),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        locale: const Locale('zh'),
        builder: (context, child) {
          loc = AppLocalizations.of(context);
          return MusicFlowTapAnchorScope(child: child!);
        },
        home: Scaffold(body: SongInfoPage(song: song)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('全空字段：可隐藏行整行不渲染，页面不崩', (tester) async {
    final song = _rich(id: 'bare');
    await pumpInfo(tester, song);

    // 无 genre / path / size / 采样率 / 位深 / 声道 → 对应行隐藏。
    expect(find.text(song.title), findsOneWidget);
    expect(find.textContaining('kbps'), findsNothing);
    expect(find.textContaining('kHz'), findsNothing);
    expect(find.textContaining('MB'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('suffix 优先做大写文件类型；采样率整数 kHz 去小数', (tester) async {
    await pumpInfo(
      tester,
      _rich(
        id: 's1',
        suffix: 'flac',
        contentType: 'audio/flac',
        bitRate: 1411,
        samplingRate: 48000,
        bitDepth: 16,
        channelCount: 2,
        size: 5242880,
        duration: 200,
      ),
    );

    expect(find.text('FLAC'), findsOneWidget, reason: '136：suffix 存在 → 大写');
    expect(find.text('48 kHz'), findsOneWidget, reason: '157：整数 kHz 不带小数');
    expect(find.text('16 bit'), findsOneWidget);
    expect(find.text('5.00 MB'), findsOneWidget);
    expect(find.text(loc!.song_info_stereo), findsOneWidget, reason: '170：2 声道');
    expect(tester.takeException(), isNull);
  });

  testWidgets('无 suffix 时回退 contentType 大写；非整数 kHz 保留一位小数', (
    tester,
  ) async {
    await pumpInfo(
      tester,
      _rich(
        id: 's2',
        contentType: 'audio/x-ape',
        bitRate: 320000,
        samplingRate: 44100,
        channelCount: 1,
        size: 1048576,
      ),
    );

    expect(find.text('AUDIO/X-APE'), findsOneWidget, reason: '138/139：contentType 回退');
    expect(find.text('44.1 kHz'), findsOneWidget, reason: '158：非整数 kHz');
    expect(find.text('320 kbps'), findsOneWidget, reason: '148：bps≥10000 → 折算 kbps');
    expect(find.text(loc!.song_info_mono), findsOneWidget, reason: '169：单声道');
    expect(find.text('1.00 MB'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('多声道：非 1/2 走 N 声道文案', (tester) async {
    await pumpInfo(
      tester,
      _rich(id: 's3', suffix: 'wav', bitRate: 1411, channelCount: 6),
    );

    expect(
      find.text(loc!.song_info_channels_count(6)),
      findsOneWidget,
      reason: '171：N 声道',
    );
    expect(find.text('1411 kbps'), findsOneWidget, reason: '149：bps<10000 按原值');
    expect(tester.takeException(), isNull);
  });

  testWidgets('currentBitRateKbps>0 时优先用当前播放码率', (tester) async {
    await pumpInfo(
      tester,
      _rich(id: 's4', suffix: 'mp3', bitRate: 128, channelCount: 2),
      currentBitRateKbps: 320,
    );

    expect(find.text('320 kbps'), findsOneWidget, reason: '145：实时码率优先');
    expect(tester.takeException(), isNull);
  });
}
