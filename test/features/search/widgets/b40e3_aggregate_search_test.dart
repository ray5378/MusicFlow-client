// batch40 E3 补测：D-010 / D-011 修复锁定用例。
//
//   D-010：聚合搜索网络区错误态不再把原始异常字符串拼进 UI 文案，
//          展示本地化通用引导文案（异常原文只送 Logger.error）；
//   D-011：AggregateLocalBlock._reload() 先取 future 再同步 setState，
//          重试不再触发 "callback argument returned a Future" 断言，
//          且错误行被成功结果替换。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/design/components/music_flow_button.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/search.dart';
import 'package:musicflow_client/features/search/widgets/aggregate_search_results.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/library/search_provider.dart';

typedef _BlockData = ({List<String> items, int total});

typedef _BlockFuture = Future<_BlockData>;

late AppLocalizations loc;

/// 有界 settle：骨架屏带 shimmer 动画，pumpAndSettle 永远等不到静止。
Future<void> _settle(WidgetTester tester, {int frames = 20}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 33));
  }
}

SearchRequest _request(SearchEntityKind kind, String query) => SearchRequest(
      kind: kind,
      mode: SearchMode.aggregate,
      query: query,
      providerId: '',
    );

Future<SearchOutcome> _stateFuture(AsyncValue<SearchOutcome> state) {
  if (state is AsyncData<SearchOutcome>) {
    return Future<SearchOutcome>.value(state.value);
  }
  if (state is AsyncError<SearchOutcome>) {
    return Future<SearchOutcome>.error(state.error);
  }
  return Completer<SearchOutcome>().future;
}

List<String> _descriptions(WidgetTester tester) =>
    tester
        .widgetList<Text>(find.byType(Text))
        .map((Text t) => t.data ?? '')
        .toList();

Finder _retryButton(WidgetTester tester) =>
    find.widgetWithText(MusicFlowButton, loc.widgets_retry);

Future<void> _pumpAggregate(
  WidgetTester tester, {
  required SearchEntityKind kind,
  required String query,
  required AsyncValue<SearchOutcome> state,
  Widget localBlock = const SizedBox.shrink(),
  Size size = const Size(900, 900),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: <Override>[
      searchResultsProvider(_request(kind, query)).overrideWith((ref) {
        return _stateFuture(state);
      }),
    ],
    child: MediaQuery(
      data: MediaQueryData(size: size),
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        theme: AppTheme.light(),
        home: Scaffold(
          body: AggregateSearchResults(
            kind: kind,
            query: query,
            localBlock: localBlock,
          ),
        ),
      ),
    ),
  ));
  await _settle(tester);
}

Future<void> _pumpBlock(
  WidgetTester tester, {
  required _BlockFuture Function() fetcher,
  String emptyText = '本地无匹配',
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(900, 900);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    child: MediaQuery(
      data: const MediaQueryData(size: Size(900, 900)),
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        theme: AppTheme.light(),
        home: Scaffold(
          body: AggregateLocalBlock<String>(
            fetcher: fetcher,
            itemBuilder: (BuildContext context, String item, int index) =>
                Text('$index:$item'),
            emptyText: emptyText,
          ),
        ),
      ),
    ),
  ));
  await _settle(tester);
}

/// 依次返回不同结果的 fetcher：用完后一直返回最后一个。
class _FetchQueue {
  _FetchQueue(List<_BlockFuture> queue)
      : _queue = List<_BlockFuture>.from(queue);

  final List<_BlockFuture> _queue;
  var calls = 0;

  _BlockFuture take() {
    final i = calls < _queue.length ? calls : _queue.length - 1;
    calls++;
    return _queue[i];
  }
}

_BlockFuture _data(List<String> items, {int? total}) =>
    _BlockFuture.value((items: items, total: total ?? items.length));

/// 造一个「会报错」的 future。额外挂一个 no-op onError 消掉
/// flutter_test zone 的未处理异步错误告警。
_BlockFuture _errorFuture(String message) {
  final future = _BlockFuture.error(StateError(message));
  unawaited(future.then<void>(
    (dynamic _) {},
    onError: (Object _, StackTrace __) {},
  ));
  return future;
}

void main() {
  setUpAll(() {
    loc = lookupAppLocalizations(const Locale('zh'));
  });

  group('D-010 错误文案外泄修复', () {
    testWidgets('网络区错误态：描述为本地化通用文案，异常原文不外泄',
        (WidgetTester tester) async {
      await _pumpAggregate(
        tester,
        kind: SearchEntityKind.song,
        query: '网络',
        state: AsyncError<SearchOutcome>(
          StateError('dio connect timeout /usr/local/secret'),
          StackTrace.empty,
        ),
      );

      expect(find.text(loc.search_network_search_failed), findsOneWidget);
      final descriptions = _descriptions(tester);
      expect(
        descriptions.any((String t) => t.contains('dio connect timeout')),
        isFalse,
        reason: '[D-010] 原始异常字符串不得拼进 UI 文案',
      );
      expect(
        descriptions.any((String t) => t.contains('请检查网络')),
        isTrue,
        reason: '[D-010] 描述应为本 地化通用引导文案',
      );
      expect(_retryButton(tester), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('D-011 _reload setState Future 断言修复', () {
    testWidgets('错误态点重试：不抛断言，数据成功替换错误行',
        (WidgetTester tester) async {
      final queue = _FetchQueue(<_BlockFuture>[
        _errorFuture('本地库读取失败'),
        _data(<String>['R0']),
      ]);
      await _pumpBlock(tester, fetcher: queue.take);

      expect(find.text(loc.search_local_load_failed), findsOneWidget);

      await tester.tap(_retryButton(tester));
      expect(
        tester.takeException(),
        isNull,
        reason: '[D-011] setState 回调不再返回 Future，重试不抛断言',
      );
      await _settle(tester);

      expect(queue.calls, 2, reason: '[D-011] _reload 确实又拉了一次');
      expect(find.text(loc.search_local_load_failed), findsNothing,
          reason: '[D-011] 错误行被数据替换');
      expect(find.text('0:R0'), findsOneWidget,
          reason: '[D-011] 重试后成功渲染数据');
    });
  });
}
