// aggregate_search_results.dart 的缺口补齐测试。
//
// 这个文件是「聚合搜索页」的结果区：本地块（页面传入）+ 全网块（走
// searchResultsProvider(SearchMode.aggregate)）。要把它从 0% 拉起来，关键是
// 把 AsyncValue 三态都逼出来：
//   loading  —— FutureProvider 的 override 返回一个永挂的 Completer future，
//               这样 provider 稳定停在 AsyncLoading（返回已完成的 future 会
//               立刻跳到 data，测不到 loading 分支）；
//   error    —— 返回 Future.error(...)；
//   data     —— 返回 SearchOutcome，再分「空 / 非空」两条。
//
// 另外 AggregateLocalBlock<T> 是本地结果块，分支比网络块还多：
// waiting / error+重试 / 空文案 / 行模式(Column) / 网格模式(GridView，
// 且 compact 与非 compact 用两个不同的 delegate)、limit 截断、cacheKey 不变不重拉。
//
// 踩过的坑：
//   a) MusicFlowSkeleton 是 ConsumerStatefulWidget(里面 watch isRenderingActiveProvider),
//      所以整棵树必须包 ProviderScope，不然一进 loading 分支就抛 "no ProviderScope"；
//   b) MusicFlowMediaListSkeleton 带 shimmer 动画会一直 tick，pumpAndSettle 等不到静止,
//      全部改有界 pump(_settle)；
//   c) windowClass 由 MediaQuery 宽度决定（musicFlowWindowClass），
//      想测 compact 分支要显式把 view.physicalSize 压到窄屏 + MediaQuery data 同步；
//   d) WidgetTester 的 pumpWidget / expect / tap 都是 guarded API，必须 await 前一个。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicflow_client/core/design/components/music_flow_anchor.dart';
import 'package:musicflow_client/core/design/components/music_flow_button.dart';
import 'package:musicflow_client/core/design/music_flow_design.dart';
import 'package:musicflow_client/core/theme/app_theme.dart';
import 'package:musicflow_client/data/models/search.dart';
import 'package:musicflow_client/features/library/widgets/library_collection_components.dart';
import 'package:musicflow_client/features/search/widgets/aggregate_search_results.dart';
import 'package:musicflow_client/l10n/generated/app_localizations.dart';
import 'package:musicflow_client/providers/library/search_provider.dart';

late AppLocalizations loc;

typedef _BlockData = ({List<String> items, int total});

typedef _BlockFuture = Future<_BlockData>;

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

SearchSong _song(String id, String name) => SearchSong(
      id: id,
      name: name,
      artist: '测试艺人',
      album: '测试专辑',
      duration: 180,
      isLocal: false,
    );

/// 把测试用的 AsyncValue 翻译成 provider 会返回的 Future。
/// loading 用永挂 Completer，稳定停在 loading 分支。
Future<SearchOutcome> _stateFuture(AsyncValue<SearchOutcome> state) {
  if (state is AsyncData<SearchOutcome>) {
    return Future<SearchOutcome>.value(state.value);
  }
  if (state is AsyncError<SearchOutcome>) {
    return Future<SearchOutcome>.error(state.error);
  }
  return Completer<SearchOutcome>().future;
}

/// 页面上所有 Text 的文本集合（错误描述是整段 '$e'，没法用 find.text 精确比）。
List<String> _descriptions(WidgetTester tester) =>
    tester.widgetList<Text>(find.byType(Text)).map((Text t) => t.data ?? '').toList();

/// 重试按钮：直接找按钮本体，别找它的文案节点（文案可能被 RichText/样式包一层）。
Finder _retryButton(WidgetTester tester) =>
    find.widgetWithText(MusicFlowButton, loc.widgets_retry);

Future<void> _pumpAggregate(
  WidgetTester tester, {
  required SearchEntityKind kind,
  required String query,
  required AsyncValue<SearchOutcome> state,
  Widget localBlock = const SizedBox.shrink(),
  void Function()? onEvaluate,
  Size size = const Size(900, 900),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: <Override>[
      searchResultsProvider(_request(kind, query)).overrideWith((ref) {
        onEvaluate?.call();
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
        home: MusicFlowTapAnchorScope(
          child: Scaffold(
            body: AggregateSearchResults(
              kind: kind,
              query: query,
              localBlock: localBlock,
            ),
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
  bool grid = false,
  int limit = 12,
  Object? cacheKey = 'k',
  Size size = const Size(900, 900),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    child: MediaQuery(
      data: MediaQueryData(size: size),
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
            grid: grid,
            limit: limit,
            cacheKey: cacheKey,
          ),
        ),
      ),
    ),
  ));
  await _settle(tester);
}

/// 用来构造「rebuild 但 cacheKey 不变 / 变了」两种场景的宿主。
class _KeyHost extends StatefulWidget {
  const _KeyHost({
    required this.toggleKey,
    required this.fixedKey,
    required this.childBuilder,
  });

  final bool toggleKey;
  final Object? fixedKey;
  final Widget Function(Object? key) childBuilder;

  @override
  State<_KeyHost> createState() => _KeyHostState();
}

class _KeyHostState extends State<_KeyHost> {
  var _alt = false;

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _alt = !_alt),
        child: widget.childBuilder(
          widget.toggleKey ? (_alt ? 'b' : 'a') : widget.fixedKey,
        ),
      );
}

/// 依次返回不同结果的 fetcher：用完后一直返回最后一个。
class _FetchQueue {
  _FetchQueue(List<_BlockFuture> queue) : _queue = List<_BlockFuture>.from(queue);

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

/// 造一个「会报错」的 future。
///
/// 必须额外挂一个空的 onError：flutter_test 的 zone 会把「没有任何 handler 接住的
/// 异步错误」当成用例失败（报 StateError 但 widget 上其实正常进了错误态），
/// 多挂一个 no-op handler 只用来消掉 zone 的未处理告警，
/// FutureBuilder 自己的 onError 照样能收到错误。
_BlockFuture _errorFuture(String message) {
  final future = _BlockFuture.error(StateError(message));
  unawaited(future.then<void>(
    (dynamic _) {},
    onError: (Object _, StackTrace __) {},
  ));
  return future;
}

void main() {
  setUp(() {
    loc = lookupAppLocalizations(const Locale('zh'));
  });

  group('AggregateSearchResults · 区块骨架', () {
    testWidgets('本地块 / 两个分区标题恒在，网络区走 loading 骨架',
        (WidgetTester tester) async {
      await _pumpAggregate(
        tester,
        kind: SearchEntityKind.song,
        query: '周杰伦',
        state: const AsyncLoading<SearchOutcome>(),
        localBlock: const Text('本地块'),
      );

      expect(find.text(loc.search_local_results), findsOneWidget);
      expect(find.text('本地块'), findsOneWidget);
      expect(find.text(loc.search_network_results), findsOneWidget);
      expect(find.text(loc.search_network_results_subtitle), findsOneWidget);
      // 骨架是一个组件内部 generate 出 6 行,find.byType 只会数到组件本身。
      expect(find.byType(MusicFlowMediaListSkeleton), findsOneWidget);
    });

    testWidgets('CustomScrollView 带 kind/query 组合的 ValueKey',
        (WidgetTester tester) async {
      await _pumpAggregate(
        tester,
        kind: SearchEntityKind.album,
        query: '范特西',
        state: const AsyncLoading<SearchOutcome>(),
      );

      final scroll = tester.widget<CustomScrollView>(find.byType(CustomScrollView));
      // 枚举插值出来的是 'SearchEntityKind.album',不是 'album'。
      expect(
        scroll.key,
        const ValueKey<String>('aggregate-search-SearchEntityKind.album-范特西'),
      );
    });

    // 注意:每个类目必须是**独立一个 test**。
    // 同一个 test 里连着 pump 多个 ProviderScope,riverpod 会复用同一个
    // ProviderContainer 并报 "Replaced the override of type Null ..." ——
    // runApp 的 updateChild 对同类型根 widget 走 update,不会重建 state。
    for (final kind in SearchEntityKind.values) {
      testWidgets('${kind.name} 类目都能构建（标题/网络区分支不依赖 kind）',
          (WidgetTester tester) async {
        await _pumpAggregate(
          tester,
          kind: kind,
          query: 'k',
          state: const AsyncLoading<SearchOutcome>(),
        );
        expect(find.text(loc.search_network_results), findsOneWidget,
            reason: '${kind.name} 应渲染网络结果标题');
      });
    }
  });

  group('AggregateSearchResults · 网络区三态', () {
    testWidgets('error -> 错误态 + 重试入口，点重试会 invalidate provider',
        (WidgetTester tester) async {
      var evaluates = 0;
      await _pumpAggregate(
        tester,
        kind: SearchEntityKind.song,
        query: '网络',
        state: AsyncError<SearchOutcome>(
            StateError('全网插件超时'), StackTrace.empty),
        onEvaluate: () => evaluates++,
      );

      expect(find.text(loc.search_network_search_failed), findsOneWidget);
      expect(_descriptions(tester).any((String t) => t.contains('全网插件超时')),
          isTrue, reason: '错误描述直接把异常文本贴出来');
      expect(_retryButton(tester), findsOneWidget);
      expect(evaluates, 1);

      await tester.tap(_retryButton(tester));
      await _settle(tester);
      expect(evaluates, 2, reason: '重试按钮应 ref.invalidate 触发重新取值');
    });

    // [D-010] 错误态把原始异常字符串（'$e'）直接展示给用户，
    // 上线后可能把插件内部路径/地址透出来，属于「内部信息外泄」级别的表现缺陷。
    testWidgets('error 文案是原始异常字符串（记录现状，待统一修复）',
        (WidgetTester tester) async {
      await _pumpAggregate(
        tester,
        kind: SearchEntityKind.song,
        query: '网络',
        state: AsyncError<SearchOutcome>(
            StateError('dio connect timeout'), StackTrace.empty),
      );

      expect(
        _descriptions(tester).any((String t) => t.contains('dio connect timeout')),
        isTrue,
        reason: '当前实现直接展示异常原文',
      );
    });

    testWidgets('data 空 -> 空态（无结果标题 + 换关键词引导）',
        (WidgetTester tester) async {
      await _pumpAggregate(
        tester,
        kind: SearchEntityKind.song,
        query: '不存在',
        state: AsyncData<SearchOutcome>(SearchOutcome()),
      );

      expect(find.text(loc.search_network_no_results), findsOneWidget);
      expect(find.text(loc.search_try_another_keyword), findsOneWidget);
      expect(find.byType(MusicFlowEmptyState), findsOneWidget);
      expect(find.byType(MusicFlowMediaListSkeleton), findsNothing);
    });

    testWidgets('data 非空 -> 走 SearchResultList 渲染歌曲卡片',
        (WidgetTester tester) async {
      await _pumpAggregate(
        tester,
        kind: SearchEntityKind.song,
        query: '周杰伦',
        state: AsyncData<SearchOutcome>(
          SearchOutcome(songs: <SearchSong>[_song('n1', '全网歌曲一')]),
        ),
        localBlock: const Text('本地块'),
      );

      expect(find.text('本地块'), findsOneWidget);
      expect(find.text('全网歌曲一'), findsWidgets);
      expect(find.text(loc.search_network_no_results), findsNothing);
    });
  });

  group('AggregateSearchResults · 与本地块组合', () {
    testWidgets('localBlock 里嵌 AggregateLocalBlock 时两路都能渲染',
        (WidgetTester tester) async {
      final queue = _FetchQueue(<_BlockFuture>[_data(<String>['L0', 'L1'])]);
      await _pumpAggregate(
        tester,
        kind: SearchEntityKind.song,
        query: '本地',
        state: const AsyncLoading<SearchOutcome>(),
        localBlock: AggregateLocalBlock<String>(
          fetcher: queue.take,
          itemBuilder: (BuildContext context, String item, int index) =>
              Text('本地$index:$item'),
          emptyText: '本地无匹配',
          cacheKey: '本地',
        ),
      );

      expect(queue.calls, 1, reason: 'initState 里就该发起本地查询');
      expect(find.text('本地0:L0'), findsOneWidget);
      expect(find.text('本地1:L1'), findsOneWidget);
    });
  });

  group('AggregateLocalBlock · 数据态', () {
    testWidgets('waiting -> 三行骨架，fetcher 只调一次',
        (WidgetTester tester) async {
      // 永挂 Completer：不能用 Future.delayed —— 测试结束时那个 timer 还没跑完,
      // flutter_test 会直接报 "A Timer is still pending"。
      final queue = _FetchQueue(<_BlockFuture>[Completer<_BlockData>().future]);
      await _pumpBlock(tester, fetcher: queue.take, limit: 5);

      expect(queue.calls, 1);
      expect(find.byType(MusicFlowMediaListSkeleton), findsOneWidget);
      expect(find.text('本地无匹配'), findsNothing);
    });

    testWidgets('行模式按 limit 截断，itemBuilder 收到递增 index',
        (WidgetTester tester) async {
      await _pumpBlock(
        tester,
        fetcher: () => _data(List<String>.generate(15, (i) => 'A$i')),
        limit: 5,
      );

      expect(find.text('0:A0'), findsOneWidget);
      expect(find.text('4:A4'), findsOneWidget);
      expect(find.text('5:A5'), findsNothing, reason: 'limit=5 只渲染前 5 条');
      expect(find.byType(GridView), findsNothing, reason: 'grid=false 走 Column');
    });

    testWidgets('空结果 -> 显示 emptyText', (WidgetTester tester) async {
      await _pumpBlock(
        tester,
        fetcher: () => _data(<String>[]),
        emptyText: '本地没有匹配',
      );

      expect(find.text('本地没有匹配'), findsOneWidget);
      expect(find.byType(MusicFlowMediaListSkeleton), findsNothing);
    });
  });

  group('AggregateLocalBlock · 网格模式', () {
    testWidgets('非 compact -> SliverGridDelegateWithMaxCrossAxisExtent',
        (WidgetTester tester) async {
      await _pumpBlock(
        tester,
        fetcher: () => _data(<String>['G0', 'G1']),
        grid: true,
        limit: 2,
      );

      final grid = tester.widget<GridView>(find.byType(GridView));
      expect(grid.gridDelegate, isA<SliverGridDelegateWithMaxCrossAxisExtent>());
    });

    testWidgets('compact -> GridView.count 三列', (WidgetTester tester) async {
      await _pumpBlock(
        tester,
        fetcher: () => _data(<String>['G0', 'G1']),
        grid: true,
        limit: 2,
        size: const Size(380, 800),
      );

      final grid = tester.widget<GridView>(find.byType(GridView));
      expect(grid.gridDelegate, isA<SliverGridDelegateWithFixedCrossAxisCount>());
      final delegate = grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
      expect(delegate.crossAxisCount, 3, reason: '移动端固定三列');
    });
  });

  group('AggregateLocalBlock · 错误与重试', () {
    testWidgets('fetcher 报错 -> 明确报错文案 + 重试按钮',
        (WidgetTester tester) async {
      final queue = _FetchQueue(<_BlockFuture>[_errorFuture('本地库读取失败')]);
      await _pumpBlock(tester, fetcher: queue.take);

      expect(find.text(loc.search_local_load_failed), findsOneWidget,
          reason: '失败 ≠ 无匹配，不能直接伪装成空');
      expect(_retryButton(tester), findsOneWidget);
    });

    // [D-011] 真实缺陷：`_reload()` 写成了
    //   setState(() => _future = widget.fetcher());
    // fetcher 返回的是 Future → setState 回调返回了 Future，
    // debug/profile 下 Flutter 的 setState 断言直接炸（"callback argument returned
    // a Future"），断言把这次状态更新整个打断：重试按钮在 debug 包里等于没反应
    // （release 包不跑断言，行为不一致）。正确写法是先取 future 再同步 setState。
    testWidgets('点重试：fetcher 确实又调了一次，但被 setState 断言打断(D-011)',
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
        isNotNull,
        reason: '手势里抛的 setState 断言（D-011）',
      );
      await _settle(tester);

      expect(queue.calls, 2, reason: '_reload 确实又拉了一次');
      expect(find.text(loc.search_local_load_failed), findsOneWidget,
          reason: 'D-011: 断言把状态更新打断，错误行还在');
      expect(find.text('0:R0'), findsNothing,
          reason: 'D-011: 重试没能把结果换成数据');
    });
  });

  group('AggregateLocalBlock · cacheKey 缓存', () {
    Future<int> _pumpHost(
      WidgetTester tester, {
      required bool toggleKey,
      required _FetchQueue queue,
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
              body: _KeyHost(
                toggleKey: toggleKey,
                fixedKey: 'a',
                childBuilder: (Object? key) => AggregateLocalBlock<String>(
                  fetcher: queue.take,
                  itemBuilder: (BuildContext context, String item, int index) =>
                      Text('$index:$item'),
                  emptyText: '本地无匹配',
                  cacheKey: key,
                ),
              ),
            ),
          ),
        ),
      ));
      await _settle(tester, frames: 5);
      return queue.calls;
    }

    testWidgets('cacheKey 不变 -> rebuild 不重新拉取', (WidgetTester tester) async {
      final queue = _FetchQueue(<_BlockFuture>[_data(<String>['S0'])]);
      final before = await _pumpHost(tester, toggleKey: false, queue: queue);
      expect(before, 1);

      await tester.tap(find.byType(GestureDetector).first);
      await _settle(tester, frames: 5);

      expect(queue.calls, 1, reason: 'cacheKey 没变就复用既有 Future');
      expect(find.text('0:S0'), findsOneWidget);
    });

    testWidgets('cacheKey 变化 -> 重新拉取', (WidgetTester tester) async {
      final queue = _FetchQueue(<_BlockFuture>[_data(<String>['S0'])]);
      final before = await _pumpHost(tester, toggleKey: true, queue: queue);
      expect(before, 1);

      await tester.tap(find.byType(GestureDetector).first);
      await _settle(tester, frames: 5);

      expect(queue.calls, 2, reason: 'didUpdateWidget 里 cacheKey 变了才 rebuild Future');
    });
  });
}
