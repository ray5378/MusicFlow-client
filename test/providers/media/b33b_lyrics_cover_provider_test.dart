import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicflow_client/data/models/lyrics.dart';
import 'package:musicflow_client/data/models/lyrics_line.dart';
import 'package:musicflow_client/data/models/music_library.dart';
import 'package:musicflow_client/data/models/provider_config.dart';
import 'package:musicflow_client/data/models/structured_lyrics.dart';
import 'package:musicflow_client/data/repositories/cover_repository.dart';
import 'package:musicflow_client/data/repositories/lyrics_repository.dart';
import 'package:musicflow_client/data/sources/database/app_database.dart';
import 'package:musicflow_client/data/sources/database/database_provider.dart';
import 'package:musicflow_client/providers/api/api_provider.dart';
import 'package:musicflow_client/providers/library/library_provider.dart';
import 'package:musicflow_client/providers/media/lyrics_cover_provider.dart';
import 'package:musicflow_client/providers/player/effective_playback_provider.dart';

import '../../helpers/mocks.dart';

/// b33b: lyrics_cover_provider.dart 补测。
/// 覆盖: 配置流映射、排序/启停/配置写入(drift 真库)、仓库按配置构造源
/// (间接覆盖 _createLyricsSource/_createCoverSource/_extractOpenSubsonicExtensions
/// 全部分支)、currentLyricLineProvider 二分滚动歌词逻辑。

/// 真数据库与 cover_providers_page_coverage_gap_test 同款:临时目录,非断言对象。
AppDatabase? sharedDb;
AppDatabase get _db => sharedDb ??= AppDatabase();

MusicLibrary _lib({Map<String, dynamic>? extensions}) => MusicLibrary(
      id: 'lib-1',
      name: 'Test',
      createdAt: DateTime(2024),
      updatedAt: DateTime(2024),
      extensions: extensions ?? const <String, dynamic>{},
    );

Future<void> _insertLyricsRow(
  String id,
  String sourceId,
  int priority, {
  bool enabled = true,
  Map<String, dynamic>? config,
}) async {
  await _db.into(_db.lyricsProviderConfigs).insert(
        LyricsProviderConfigsCompanion.insert(
          id: id,
          sourceId: sourceId,
          priority: priority,
          enabled: Value(enabled),
          config: config == null ? const Value.absent() : Value(jsonEncode(config)),
        ),
      );
}

Future<void> _insertCoverRow(
  String id,
  String sourceId,
  int priority, {
  bool enabled = true,
  Map<String, dynamic>? config,
}) async {
  await _db.into(_db.coverProviderConfigs).insert(
        CoverProviderConfigsCompanion.insert(
          id: id,
          sourceId: sourceId,
          priority: priority,
          enabled: Value(enabled),
          config: config == null ? const Value.absent() : Value(jsonEncode(config)),
        ),
      );
}

Future<void> _clearRows() async {
  await _db.delete(_db.lyricsProviderConfigs).go();
  await _db.delete(_db.coverProviderConfigs).go();
}

Future<List<LyricsProviderConfigData>> _lyricsRows() =>
    (_db.select(_db.lyricsProviderConfigs)
          ..orderBy([(t) => OrderingTerm.asc(t.id)]))
        .get();

Future<List<CoverProviderConfigData>> _coverRows() =>
    (_db.select(_db.coverProviderConfigs)
          ..orderBy([(t) => OrderingTerm.asc(t.id)]))
        .get();

ProviderConfig _toLyricsConfig(LyricsProviderConfigData r) => ProviderConfig(
      id: r.id,
      sourceId: r.sourceId,
      enabled: r.enabled,
      priority: r.priority,
      config: r.config == null ? null : jsonDecode(r.config!) as Map<String, dynamic>,
    );

ProviderConfig _toCoverConfig(CoverProviderConfigData r) => ProviderConfig(
      id: r.id,
      sourceId: r.sourceId,
      enabled: r.enabled,
      priority: r.priority,
      config: r.config == null ? null : jsonDecode(r.config!) as Map<String, dynamic>,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // AppDatabase 的 LazyDatabase 走 getApplicationDocumentsDirectory,
  // 测试里必须 mock 平台通道(踩坑 #195-D:通道名带 plugins.flutter.io 前缀)。
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (MethodCall call) async => '/tmp/mf_b33b_lyrics_cover',
  );
  // 清掉上次进程留下的 db.sqlite,避免撞 UNIQUE 约束(踩坑 #202-D)。
  final tmpDir = Directory('/tmp/mf_b33b_lyrics_cover');
  if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  tmpDir.createSync(recursive: true);

  setUp(() async {
    await _clearRows();
  });

  group('配置流 Provider', () {
    test('lyricsProviderConfigsProvider: 按 priority 升序映射并解码 config JSON',
        () async {
      await _insertLyricsRow('l1', 'lrclib', 1,
          config: <String, dynamic>{'url': 'http://t/{id}'});
      await _insertLyricsRow('l0', 'subsonic', 0, enabled: false);

      final container = ProviderContainer(overrides: <Override>[
        appDatabaseProvider.overrideWith((ref) => _db),
      ]);
      addTearDown(container.dispose);

      final configs =
          await container.read(lyricsProviderConfigsProvider.future);
      expect(configs.length, 2);
      expect(configs.first.id, 'l0');
      expect(configs.first.enabled, isFalse);
      expect(configs.first.config, isNull);
      expect(configs.last.id, 'l1');
      expect(configs.last.enabled, isTrue);
      expect(configs.last.config, <String, dynamic>{'url': 'http://t/{id}'});
    });

    test('coverProviderConfigsProvider: config 为 null 的行映射 config=null',
        () async {
      await _insertCoverRow('c0', 'subsonic', 0);

      final container = ProviderContainer(overrides: <Override>[
        appDatabaseProvider.overrideWith((ref) => _db),
      ]);
      addTearDown(container.dispose);

      final configs = await container.read(coverProviderConfigsProvider.future);
      expect(configs.length, 1);
      expect(configs.single.sourceId, 'subsonic');
      expect(configs.single.priority, 0);
      expect(configs.single.config, isNull);
    });
  });

  group('配置管理写路径', () {
    test('updateLyricsProviderOrder: 按传入顺序重写 priority', () async {
      await _insertLyricsRow('a', 'lrclib', 0);
      await _insertLyricsRow('b', 'netease', 1);
      await _insertLyricsRow('c', 'subsonic', 2);

      final rows = await _lyricsRows();
      final byId = <String, LyricsProviderConfigData>{
        for (final r in rows) r.id: r,
      };
      final reordered = <ProviderConfig>[
        _toLyricsConfig(byId['c']!),
        _toLyricsConfig(byId['a']!),
        _toLyricsConfig(byId['b']!),
      ];

      await updateLyricsProviderOrder(_db, reordered);

      final after = await _lyricsRows();
      final afterById = <String, int>{
        for (final r in after) r.id: r.priority,
      };
      expect(afterById['c'], 0);
      expect(afterById['a'], 1);
      expect(afterById['b'], 2);
    });

    test('updateCoverProviderOrder: 按传入顺序重写 priority', () async {
      await _insertCoverRow('a', 'subsonic', 0);
      await _insertCoverRow('b', 'fanart', 1);

      final rows = await _coverRows();
      final byId = <String, CoverProviderConfigData>{
        for (final r in rows) r.id: r,
      };
      final reordered = <ProviderConfig>[
        _toCoverConfig(byId['b']!),
        _toCoverConfig(byId['a']!),
      ];

      await updateCoverProviderOrder(_db, reordered);

      final after = await _coverRows();
      final afterById = <String, int>{
        for (final r in after) r.id: r.priority,
      };
      expect(afterById['b'], 0);
      expect(afterById['a'], 1);
    });

    test('toggleLyricsProvider: 停用与再启用', () async {
      await _insertLyricsRow('a', 'lrclib', 0);
      expect((await _lyricsRows()).first.enabled, isTrue);

      await toggleLyricsProvider(_db, 'a', false);
      expect((await _lyricsRows()).first.enabled, isFalse);

      await toggleLyricsProvider(_db, 'a', true);
      expect((await _lyricsRows()).first.enabled, isTrue);
    });

    test('toggleCoverProvider: 停用与再启用', () async {
      await _insertCoverRow('a', 'fanart', 0);
      expect((await _coverRows()).first.enabled, isTrue);

      await toggleCoverProvider(_db, 'a', false);
      expect((await _coverRows()).first.enabled, isFalse);

      await toggleCoverProvider(_db, 'a', true);
      expect((await _coverRows()).first.enabled, isTrue);
    });

    test('updateCoverProviderConfig: 有效配置写入 JSON 字符串', () async {
      await _insertCoverRow('a', 'custom', 0);

      await updateCoverProviderConfig(
          _db, 'a', <String, dynamic>{'url': 'http://c/{id}'});

      final row = (await _coverRows()).first;
      expect(row.config, '{"url":"http://c/{id}"}');
    });

    test('updateCoverProviderConfig: 全空白值/null → 写入 null', () async {
      await _insertCoverRow('a', 'custom', 0);

      await updateCoverProviderConfig(
          _db, 'a', <String, dynamic>{'apiKey': '   '});
      expect((await _coverRows()).first.config, isNull);

      await updateCoverProviderConfig(_db, 'a', null);
      expect((await _coverRows()).first.config, isNull);
    });
  });

  group('仓库按配置构造源(覆盖 sourceId switch 分支)', () {
    test('lyricsRepositoryProvider: subsonic/lrclib/netease/custom/default + '
        'disabled 过滤 + extensions(supported 形状) 解析', () async {
      await _insertLyricsRow('r0', 'subsonic', 0);
      await _insertLyricsRow('r1', 'lrclib', 1);
      await _insertLyricsRow('r2', 'netease', 2);
      await _insertLyricsRow('r3', 'custom', 3,
          config: <String, dynamic>{'url': 'http://c/{id}'});
      // default 分支: 未知 sourceId → LrclibLyricsSource。
      await _insertLyricsRow('r4', 'mystery', 4);
      // disabled 行应被过滤,不参与构造。
      await _insertLyricsRow('r5', 'netease2', 5, enabled: false);

      final api = MockSubsonicApiClient();
      final container = ProviderContainer(overrides: <Override>[
        appDatabaseProvider.overrideWith((ref) => _db),
        activeLibraryProvider.overrideWithValue(_lib(extensions: <String,
            dynamic>{
          'supported': <String>['songLyrics'],
          'serverFingerprint': 'fp',
        })),
        subsonicApiClientProvider.overrideWithValue(api),
      ]);
      addTearDown(container.dispose);

      // 先订阅配置流让 StreamProvider 缓存数据,仓库构造时才能看到配置。
      final sub = container.listen(lyricsProviderConfigsProvider, (_, _) {});
      addTearDown(sub.close);
      await container.read(lyricsProviderConfigsProvider.future);

      final LyricsRepository repo = container.read(lyricsRepositoryProvider);
      expect(repo, isNotNull);
    });

    test('lyricsRepositoryProvider: extensions 旧版形状(顶层键) 解析分支', () async {
      final api = MockSubsonicApiClient();
      final container = ProviderContainer(overrides: <Override>[
        appDatabaseProvider.overrideWith((ref) => _db),
        activeLibraryProvider.overrideWithValue(_lib(extensions: <String,
            dynamic>{
          'songLyrics': <String, dynamic>{},
        })),
        subsonicApiClientProvider.overrideWithValue(api),
      ]);
      addTearDown(container.dispose);
      final sub = container.listen(lyricsProviderConfigsProvider, (_, _) {});
      addTearDown(sub.close);
      await container.read(lyricsProviderConfigsProvider.future);

      expect(container.read(lyricsRepositoryProvider), isNotNull);
    });

    test('coverRepositoryProvider: subsonic/fanart/musicbrainz/custom/default '
        '分支', () async {
      await _insertCoverRow('r0', 'subsonic', 0);
      await _insertCoverRow('r1', 'fanart', 1,
          config: <String, dynamic>{'apiKey': 'k'});
      await _insertCoverRow('r2', 'musicbrainz', 2);
      await _insertCoverRow('r3', 'custom', 3,
          config: <String, dynamic>{'url': 'http://c/{id}'});
      // default 分支: 未知 sourceId → SubsonicCoverSource。
      await _insertCoverRow('r4', 'mystery', 4);

      final api = MockSubsonicApiClient();
      final container = ProviderContainer(overrides: <Override>[
        appDatabaseProvider.overrideWith((ref) => _db),
        subsonicApiClientProvider.overrideWithValue(api),
      ]);
      addTearDown(container.dispose);
      final sub = container.listen(coverProviderConfigsProvider, (_, _) {});
      addTearDown(sub.close);
      await container.read(coverProviderConfigsProvider.future);

      final CoverRepository repo = container.read(coverRepositoryProvider);
      expect(repo, isNotNull);
    });
  });

  group('currentLyricLineProvider(二分滚动歌词)', () {
    final syncedLines = StructuredLyrics(
      synced: true,
      lang: 'en',
      offsetMs: 0,
      lines: <LyricsLine>[
        LyricsLine(startMs: 0, value: 'first'),
        LyricsLine(startMs: 1000, value: 'second'),
        LyricsLine(startMs: 2000, value: 'third'),
      ],
    );

    ProviderContainer lineContainer({
      required Lyrics? lyrics,
      required Duration position,
    }) =>
        ProviderContainer(overrides: <Override>[
          currentLyricsProvider.overrideWith((ref) async => lyrics),
          effectivePositionProvider.overrideWith((ref) => position),
        ]);


    test('歌词为 null → 返回 null', () async {
      final c = lineContainer(lyrics: null, position: Duration.zero);
      addTearDown(c.dispose);
      await c.read(currentLyricsProvider.future);
      expect(c.read(currentLyricLineProvider), isNull);
    });

    test('无同步歌词(unsynced) → 返回 null', () async {
      final lyrics = Lyrics(
        sourceId: 'x',
        entries: <StructuredLyrics>[
          StructuredLyrics(
            synced: false,
            lines: <LyricsLine>[LyricsLine(value: 'plain')],
          ),
        ],
      );
      final c =
          lineContainer(lyrics: lyrics, position: Duration.zero);
      addTearDown(c.dispose);
      await c.read(currentLyricsProvider.future);
      expect(c.read(currentLyricLineProvider), isNull);
    });

    test('同步但行为空 → 返回 null', () async {
      final lyrics = Lyrics(
        sourceId: 'x',
        entries: <StructuredLyrics>[
          StructuredLyrics(synced: true, lines: const <LyricsLine>[]),
        ],
      );
      final c =
          lineContainer(lyrics: lyrics, position: Duration.zero);
      addTearDown(c.dispose);
      await c.read(currentLyricsProvider.future);
      expect(c.read(currentLyricLineProvider), isNull);
    });

    test('位置 0 → 命中第一行', () async {
      final lyrics = Lyrics(sourceId: 'x', entries: [syncedLines]);
      final c =
          lineContainer(lyrics: lyrics, position: Duration.zero);
      addTearDown(c.dispose);
      await c.read(currentLyricsProvider.future);
      expect(c.read(currentLyricLineProvider), 'first');
    });

    test('位置 1500ms → 命中第二行;2500ms → 第三行', () async {
      final lyrics = Lyrics(sourceId: 'x', entries: [syncedLines]);
      final c1 = lineContainer(
          lyrics: lyrics, position: const Duration(milliseconds: 1500));
      addTearDown(c1.dispose);
      await c1.read(currentLyricsProvider.future);
      expect(c1.read(currentLyricLineProvider), 'second');

      final c2 = lineContainer(
          lyrics: lyrics, position: const Duration(milliseconds: 2500));
      addTearDown(c2.dispose);
      await c2.read(currentLyricsProvider.future);
      expect(c2.read(currentLyricLineProvider), 'third');
    });

    test('offsetMs 参与匹配: offset 500 时 1200ms 仍在第一行、1500ms 进入第二行',
        () async {
      final offsetLines = StructuredLyrics(
        synced: true,
        offsetMs: 500,
        lines: <LyricsLine>[
          LyricsLine(startMs: 0, value: 'first'),
          LyricsLine(startMs: 1000, value: 'second'),
        ],
      );
      final lyrics = Lyrics(sourceId: 'x', entries: [offsetLines]);

      final c1 = lineContainer(
          lyrics: lyrics, position: const Duration(milliseconds: 1200));
      addTearDown(c1.dispose);
      await c1.read(currentLyricsProvider.future);
      expect(c1.read(currentLyricLineProvider), 'first');

      final c2 = lineContainer(
          lyrics: lyrics, position: const Duration(milliseconds: 1500));
      addTearDown(c2.dispose);
      await c2.read(currentLyricsProvider.future);
      expect(c2.read(currentLyricLineProvider), 'second');
    });

    test('命中空白行 → 返回 null(调用方回退歌手名)', () async {
      final emptyLine = StructuredLyrics(
        synced: true,
        lines: <LyricsLine>[
          LyricsLine(startMs: 0, value: 'first'),
          LyricsLine(startMs: 1000, value: '   '),
        ],
      );
      final lyrics = Lyrics(sourceId: 'x', entries: [emptyLine]);
      final c = lineContainer(
          lyrics: lyrics, position: const Duration(milliseconds: 1500));
      addTearDown(c.dispose);
      await c.read(currentLyricsProvider.future);
      expect(c.read(currentLyricLineProvider), isNull);
    });

    test('超过最后一行起点 → 停在最后一行', () async {
      final lyrics = Lyrics(sourceId: 'x', entries: [syncedLines]);
      final c = lineContainer(
          lyrics: lyrics, position: const Duration(seconds: 99));
      addTearDown(c.dispose);
      await c.read(currentLyricsProvider.future);
      expect(c.read(currentLyricLineProvider), 'third');
    });
  });
}
