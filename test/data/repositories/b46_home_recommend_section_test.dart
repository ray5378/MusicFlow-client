// b46 —— 首页聚合端点接入（服务端契约钉子）
//
// 背景：客户端「为你推荐」不再自己拼「固定卡 + 4 页翻页 shuffle」，改为
// 直接消费服务端聚合快照 `GET /rest/api/v1/home/recommend-section`；
// 「最近更新的歌单」改走 `GET /rest/api/v1/home/recent-playlists`。
//
// 本文件钉住数据层契约：
//   * HomeCard.fromJson 缺 `playlistId`（null / 缺键）不崩 —— 旧实现是硬 cast
//     `as String`，一条坏卡会让整批固定卡解析抛 CastError。
//   * HomeRecommendSection.fromJson 解析 hourBucket / homeCount / degraded /
//     fixed / random，且**不做任何 songCount 过滤**（门槛已由服务端负责）。
//   * 响应体形态异常（null / List）不抛 CastError（对齐 getHomeSections 写法）。
//   * 请求异常向上抛，由 provider 置 homeCardsLoadFailedProvider。
//   * getRecentPlaylists 透传 limit 且按服务端顺序原样解析。
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:musicflow_client/data/models/recommend.dart';
import 'package:musicflow_client/data/repositories/playlist_repository.dart';
import 'package:musicflow_client/data/repositories/recommend_repository.dart';

import '../../helpers/mocks.dart';

Map<String, dynamic> _cardJson(
  String id,
  int songCount, {
  bool? missing,
}) =>
    <String, dynamic>{
      'playlistId': id,
      'name': 'Card $id',
      'playlistName': 'Card $id',
      'position': 1,
      'isCombo': false,
      'songCount': songCount,
      'coverArt': 'pl-$id',
      if (missing != null) 'missing': missing,
    };

void main() {
  group('HomeCard.fromJson', () {
    test('playlistId 缺键 → 不崩，回落空串', () {
      final card = HomeCard.fromJson(<String, dynamic>{
        'name': '坏卡',
        'songCount': 30,
      });
      expect(card.playlistId, isEmpty);
      expect(card.songCount, 30);
    });

    test('playlistId 为 null → 不崩，回落空串', () {
      final card = HomeCard.fromJson(<String, dynamic>{
        'playlistId': null,
        'name': '坏卡',
      });
      expect(card.playlistId, isEmpty);
    });

    test('missing 缺省 false；异常卡保留 true', () {
      expect(HomeCard.fromJson(_cardJson('c1', 50)).missing, isFalse);
      expect(HomeCard.fromJson(_cardJson('c1', 50, missing: true)).missing, isTrue);
    });

    test('songCount 为浮点/字符串数字 → 容错取整', () {
      final card = HomeCard.fromJson(<String, dynamic>{
        'playlistId': 'c1',
        'songCount': 30.0,
      });
      expect(card.songCount, 30);
    });
  });

  group('HomeRecommendSection.fromJson', () {
    test('完整快照 → 10 固定 + 2 随机零门槛解析', () {
      final section = HomeRecommendSection.fromJson(<String, dynamic>{
        'success': true,
        'hourBucket': 498541,
        'homeCount': 12,
        'degraded': false,
        'fixed': <dynamic>[
          _cardJson('pl-daily-roam', 4142),
          _cardJson('pl-daily-today', 779),
          _cardJson('pl-daily-local', 500),
          _cardJson('pl-random-songs', 369),
          _cardJson('qq-today', 30),
          _cardJson('netease-today', 30),
          _cardJson('kugou-today', 30),
          _cardJson('netease-history', 574),
          _cardJson('qq-history', 300),
          _cardJson('kugou-history', 588),
        ],
        'random': <dynamic>[
          {'id': 'pl-a', 'name': 'A', 'songCount': 303, 'coverArt': 'pl-pl-a'},
          {'id': 'pl-b', 'name': 'B', 'songCount': 12},
        ],
      });

      expect(section.hourBucket, 498541);
      expect(section.homeCount, 12);
      expect(section.degraded, isFalse);
      expect(section.fixed.length, 10, reason: '服务端零门槛，客户端不得过滤');
      expect(section.fixed.where((c) => c.songCount == 30).length, 3,
          reason: '30 首的卡旧实现会被 >30 门槛误杀');
      expect(section.random.length, 2);
      expect(section.random.first.id, 'pl-a');
      expect(section.random.first.songCount, 303);
      // 随机补位只带四个字段，缺 duration 时归一化为 0（Playlist.fromJson 要求必填）。
      expect(section.random.last.duration, 0);
      expect(section.isEmpty, isFalse);
    });

    test('degraded=true + fixed 空 + random 非空 → isEmpty 为 false', () {
      final section = HomeRecommendSection.fromJson(<String, dynamic>{
        'hourBucket': 1,
        'homeCount': 12,
        'degraded': true,
        'fixed': <dynamic>[],
        'random': <dynamic>[
          {'id': 'pl-a', 'name': 'A', 'songCount': 303},
        ],
      });
      expect(section.degraded, isTrue);
      expect(section.fixed, isEmpty);
      expect(section.isEmpty, isFalse,
          reason: 'UI 判定要看 degraded，不能只看 isEmpty');
    });

    test('缺全部键 → 空快照（不抛）', () {
      final section = HomeRecommendSection.fromJson(<String, dynamic>{});
      expect(section.isEmpty, isTrue);
      expect(section.hourBucket, 0);
      expect(section.homeCount, 0);
      expect(section.degraded, isFalse);
    });
  });

  group('RecommendRepository.getHomeRecommendSection', () {
    test('解析服务端响应', () async {
      final api = MockSubsonicApiClient();
      when(() => api.getRaw(any())).thenAnswer(
        (_) async => <String, dynamic>{
          'success': true,
          'hourBucket': 498541,
          'homeCount': 12,
          'degraded': true,
          'fixed': <dynamic>[_cardJson('c1', 30, missing: true)],
          'random': <dynamic>[],
        },
      );

      final section = await RecommendRepository(api).getHomeRecommendSection();
      expect(section.hourBucket, 498541);
      expect(section.degraded, isTrue);
      expect(section.fixed.single.playlistId, 'c1');
      expect(section.fixed.single.missing, isTrue);
      verify(() => api.getRaw('/rest/api/v1/home/recommend-section')).called(1);
    });

    test('响应体为 List → 空快照且不抛 CastError', () async {
      final api = MockSubsonicApiClient();
      when(() => api.getRaw(any())).thenAnswer((_) async => <dynamic>[]);

      final section = await RecommendRepository(api).getHomeRecommendSection();
      expect(section.isEmpty, isTrue);
    });

    test('响应体为 null → 空快照且不抛', () async {
      final api = MockSubsonicApiClient();
      when(() => api.getRaw(any())).thenAnswer((_) async => null);

      final section = await RecommendRepository(api).getHomeRecommendSection();
      expect(section.isEmpty, isTrue);
    });

    test('兼容 subsonic-response 包裹形态', () async {
      final api = MockSubsonicApiClient();
      when(() => api.getRaw(any())).thenAnswer(
        (_) async => <String, dynamic>{
          'subsonic-response': <String, dynamic>{
            'hourBucket': 7,
            'homeCount': 3,
            'degraded': false,
            'fixed': <dynamic>[_cardJson('c1', 10)],
            'random': <dynamic>[],
          },
        },
      );

      final section = await RecommendRepository(api).getHomeRecommendSection();
      expect(section.hourBucket, 7);
      expect(section.fixed.single.playlistId, 'c1');
    });

    test('请求异常 → rethrow（由 provider 置失败标记）', () async {
      final api = MockSubsonicApiClient();
      when(() => api.getRaw(any())).thenThrow(StateError('boom'));

      expect(
        () => RecommendRepository(api).getHomeRecommendSection(),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('PlaylistRepository.getRecentPlaylists', () {
    test('透传 limit 并按服务端顺序原样解析', () async {
      final api = MockSubsonicApiClient();
      when(
        () => api.getRaw(
          any(),
          queryParameters: any(named: 'queryParameters'),
        ),
      ).thenAnswer(
        (_) async => <String, dynamic>{
          'success': true,
          'limit': 20,
          'items': <dynamic>[
            {
              'id': 'pl-random-songs',
              'name': '随机歌曲',
              'songCount': 373,
              'coverArt': 'pl-pl-random-songs',
              'changed': '2026-11-15T12:36:43.461Z',
            },
            {
              'id': 'pl-a',
              'name': 'A',
              'songCount': 10,
              'changed': '2026-11-14T12:00:00.000Z',
            },
          ],
        },
      );

      final list = await PlaylistRepository(api).getRecentPlaylists();
      expect(
        list.map((p) => p.id).toList(),
        <String>['pl-random-songs', 'pl-a'],
        reason: '服务端已按 updated_at 倒序，客户端不得重排',
      );
      expect(list.first.songCount, 373);

      final captured = verify(
        () => api.getRaw(
          '/rest/api/v1/home/recent-playlists',
          queryParameters: captureAny(named: 'queryParameters'),
        ),
      ).captured.single as Map<String, dynamic>;
      expect(captured['limit'], '20', reason: '默认 limit=20 必须显式下发');
    });

    test('自定义 limit 透传', () async {
      final api = MockSubsonicApiClient();
      when(
        () => api.getRaw(
          any(),
          queryParameters: any(named: 'queryParameters'),
        ),
      ).thenAnswer((_) async => <String, dynamic>{'items': <dynamic>[]});

      await PlaylistRepository(api).getRecentPlaylists(limit: 5);
      final captured = verify(
        () => api.getRaw(
          any(),
          queryParameters: captureAny(named: 'queryParameters'),
        ),
      ).captured.single as Map<String, dynamic>;
      expect(captured['limit'], '5');
    });

    test('响应体形态异常 → 空列表（不抛）', () async {
      final api = MockSubsonicApiClient();
      when(
        () => api.getRaw(
          any(),
          queryParameters: any(named: 'queryParameters'),
        ),
      ).thenAnswer((_) async => <dynamic>[]);

      expect(await PlaylistRepository(api).getRecentPlaylists(), isEmpty);
    });

    test('请求异常 → rethrow', () async {
      final api = MockSubsonicApiClient();
      when(
        () => api.getRaw(
          any(),
          queryParameters: any(named: 'queryParameters'),
        ),
      ).thenThrow(StateError('boom'));

      expect(
        () => PlaylistRepository(api).getRecentPlaylists(),
        throwsA(isA<StateError>()),
      );
    });
  });
}
