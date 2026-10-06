// b38c3 —— Route C 补测：synced_lyrics_view.dart 剩余缺口。
//   * 157：SyncedLyricsView.build 里传给 Surface 的 `onSeek: (target) =>
//     seekEffectivePlayback(ref, target)` 闭包体（点歌词行触发）。
//   * 205-208：SyncedLyricsSurface.didUpdateWidget 中 `oldWidget.lyrics != widget.lyrics`
//     时重置 _currentIndex/_hasInitialAutoPositioned/_isUserScrolling/取消 timer。
//
// 手法：SyncedLyricsView 挂 ProviderScope + frozenPosition/ cast/dlna 桩；点行 → onSeek
// 路由到 castPeer.seek（本机链路）。didUpdateWidget 用 provider-free 的
// SyncedLyricsSurface 连续 pump 两份不同歌词触发。
//
// 只写 test/，只读 lib/（产品代码零改动）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/lyrics_line.dart';
import 'package:musicflow_client/data/models/structured_lyrics.dart';
import 'package:musicflow_client/features/player/widgets/synced_lyrics_view.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/cast/cast_peer_provider.dart';
import 'package:musicflow_client/providers/cast/dlna_provider.dart';
import 'package:musicflow_client/providers/player/frozen_playback_provider.dart';
import 'package:musicflow_client/providers/player/player_provider.dart';

import '../test_player_notifier.dart';

class _StubCastPeer extends CastPeerController {
  _StubCastPeer(super.ref);

  final List<String> calls = <String>[];

  @override
  Future<void> seek(Duration position) async {
    calls.add('seek:${position.inMilliseconds}');
  }
}

class _StubDlnaCast extends DlnaCastNotifier {
  _StubDlnaCast(super.ref);
}

class _StubFrozenPosition extends FrozenPositionNotifier {
  _StubFrozenPosition(this._read);
  final Duration Function() _read;
  @override
  Duration build() => _read();
}

Future<void> settle(WidgetTester tester, {int frames = 10}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

StructuredLyrics _lyrics(String first, String second, String third) =>
    StructuredLyrics(
      synced: true,
      offsetMs: 0,
      lines: <LyricsLine>[
        LyricsLine(startMs: 0, value: first),
        LyricsLine(startMs: 1000, value: second),
        LyricsLine(startMs: 2000, value: third),
      ],
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('SyncedLyricsView：点歌词行 → onSeek 闭包 → seekEffectivePlayback（157）',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    late _StubCastPeer cast;
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          playerProvider.overrideWith(
            (Ref ref) => TestPlayerNotifier(PlayerState()),
          ),
          castPeerControllerProvider.overrideWith((Ref ref) {
            cast = _StubCastPeer(ref)..state = const CastPeerState();
            return cast;
          }),
          dlnaCastProvider.overrideWith((Ref ref) => _StubDlnaCast(ref)),
          frozenPositionProvider.overrideWith(
            () => _StubFrozenPosition(() => const Duration(milliseconds: 500)),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          theme: AppTheme.light(),
          home: Scaffold(
            body: SizedBox(
              height: 500,
              child: SyncedLyricsView(
                lyrics: _lyrics('第一行', '第二行', '第三行'),
                fullPlayerActive: true,
              ),
            ),
          ),
        ),
      ),
    );
    await settle(tester);

    expect(find.text('第二行'), findsOneWidget);
    await tester.tap(find.text('第二行'));
    await settle(tester);

    expect(cast.calls, contains('seek:1000'),
        reason: 'onSeek 闭包应路由到 seekEffectivePlayback（本机 → castPeer.seek）');
    expect(tester.takeException(), isNull);
  });

  testWidgets('SyncedLyricsSurface：歌词替换触发 didUpdateWidget 重置（205-208）',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final seeks = <Duration>[];
    Widget host(StructuredLyrics lyrics) => MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          theme: AppTheme.light(),
          home: Scaffold(
            body: SizedBox(
              height: 500,
              child: SyncedLyricsSurface(
                lyrics: lyrics,
                position: const Duration(milliseconds: 1500),
                onSeek: (Duration d) async => seeks.add(d),
              ),
            ),
          ),
        );

    await tester.pumpWidget(host(_lyrics('a1', 'a2', 'a3')));
    await settle(tester);
    expect(find.text('a2'), findsOneWidget);

    // 换一份不同歌词 → oldWidget.lyrics != widget.lyrics → 走重置分支。
    await tester.pumpWidget(host(_lyrics('b1', 'b2', 'b3')));
    await settle(tester);

    expect(find.text('b2'), findsOneWidget);
    expect(find.text('a2'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
