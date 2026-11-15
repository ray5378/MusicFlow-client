import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:musicflow_client/core/network/address_pool.dart';
import 'package:musicflow_client/core/l10n/localizations.dart';
import 'package:musicflow_client/core/utils/logger.dart';
import 'package:musicflow_client/core/utils/network_error_notifier.dart';
import 'package:musicflow_client/core/utils/server_url_security.dart';
import 'package:musicflow_client/core/utils/toast_notifier.dart';

/// 请求兜底拦截器。
///
/// 三项职责，按「先便宜后昂贵」的顺序：
///   1. [onRequest] 给请求补 `baseUrl`（活跃地址为空时退一步用池内最优地址）；
///   2. [onError] 对连接类错误做**同地址受限重试**（0 / 1s / 2s）；
///   3. 同地址重试耗尽后，才在**多地址**池里切线路（单地址没有下一跳）。
class FallbackInterceptor extends Interceptor {
  static const _tag = 'FALLBACK';

  /// 非幂等请求（POST 等）用它显式关闭自动重放：`extra[key] == false`。
  static const allowRetryExtraKey = 'musicflow.allowFallbackRetry';

  /// 「同一地址上已重试次数」在 [RequestOptions.extra] 里的键。
  ///
  /// 计数必须挂在 options 上而不是实例字段：重试是 `_dio.fetch(同一 options)`
  /// 递归回到本拦截器，只有 extra 能跨递归层传递，也天然按「单条逻辑请求」
  /// 隔离（实例字段会被十几条并发请求互相覆盖）。
  static const sameAddressRetryCountKey = 'musicflow.sameAddressRetryCount';

  /// 「本次逻辑请求的同地址重试预算」在 [RequestOptions.extra] 里的键。
  ///
  /// 预算按「有没有健康备线」分档（1 或 3），且必须在首个失败帧钉住 ——
  /// 切线路后原线路变 failed，重算会把预算抬回 3，把故障放大成 1+3 次。
  static const _retryBudgetExtraKey = 'musicflow.sameAddressRetryBudget';

  /// 「**没有备线时**」同一地址最多重试的次数，对应退避 0 / 1s / 2s。
  ///
  /// 有健康备线时实际预算只有 1 次（见 [onError] 里的 hasNextHop 分档）：
  /// 有别的路就直接换路，不该在死路上白等退避。
  static const int maxSameAddressRetries = 3;

  /// 重试令牌桶：任意 [retryTokenWindow] 窗口内最多 [retryTokenLimit] 次重试。
  ///
  /// 断网 / 黑洞隧道下每条请求都会「失败 → 重试 → 再失败」，没有上限就是
  /// 自我 DDoS；而首屏是十几条请求并发发出，更必须封顶。
  ///
  /// 只计**延时重试**（attempt >= 1）；零延时的 attempt 0 免令牌，理由见
  /// [onError] 第 5 步的注释。
  ///
  /// **覆盖面（别误以为它是全链路风暴保护）**：本桶实际只约束「**无备线**」
  /// 拓扑下的延时波 —— 只有那一档预算为 3，才会产生 1s / 2s 两波重试。有健康
  /// 备线时预算为 1、attempt 0 又免令牌，本桶根本不会被用到；那条拓扑的 burst
  /// 上界由「预算 1」+ [_failoverInFlight]（切换期间不并发放大）共同给出，每条
  /// 逻辑请求至多 2 次。
  /// 所以**不要**把 attempt 0 计费加回来当风暴保护：那会同时砍掉首屏十几条
  /// 请求的自愈机会（把 attempt 0 纳回令牌桶的变异已实测：14 条里 12 条成功、
  /// 2 条直接失败，正是本批要修的「该自愈的没自愈」）。
  static const int retryTokenLimit = 12;
  static const Duration retryTokenWindow = Duration(seconds: 10);

  /// 令牌桶时间戳（只保留窗口内的）。
  static final List<DateTime> _retryStamps = <DateTime>[];

  /// 测试钩子：令牌桶时钟。生产恒为 `DateTime.now`。
  static DateTime Function() retryClock = DateTime.now;

  /// 测试钩子：重试退避时长。生产恒为 [defaultRetryBackoff]。
  static Duration Function(int attempt) retryBackoff = defaultRetryBackoff;

  /// 默认退避：attempt 0 → 立刻重试；1 → 1s；2 → 2s。
  ///
  /// 第一次退避刻意取 0：要救的瞬时失败是「请求已经发到线上、对端在给出响应
  /// 前断开」—— 服务端 keep-alive 超时与客户端不同步、反代重启、NAT 表项老化
  /// 都会造成这种半开连接。这类失败重发一次即可自愈，多睡 1s 是纯损失。
  ///
  /// 注意：**不是**「复用到对端已关闭的空闲 keep-alive 连接」。真实 socket
  /// 实验证明该场景在 dart:io 上不成立 —— `HttpClient` 在连接关闭时会立刻把
  /// 它从 idle 池剔除，陈旧连接根本不会被复用（证据：重试帧 0 个、写入已死
  /// 连接的字节 0 个、远端端口每次新建）。不要照这个错误前提做优化。
  static Duration defaultRetryBackoff(int attempt) {
    if (attempt <= 0) return Duration.zero;
    return Duration(milliseconds: 1000 << (attempt - 1));
  }

  /// 测试用：清空令牌桶并恢复默认时钟 / 退避。
  ///
  /// 这些是 static 状态，会跨用例污染（一个用例烧掉的令牌会让下一个用例
  /// 莫名「不重试」），所以凡是碰到本拦截器的用例都应在 setUp 里调用。
  static void resetRetryStateForTest() {
    _retryStamps.clear();
    retryClock = DateTime.now;
    retryBackoff = defaultRetryBackoff;
  }

  /// 当前窗口内已用掉的令牌数（测试断言「断网不消耗令牌」用）。
  @visibleForTesting
  static int get retryTokensUsedForTest => _retryStamps.length;

  final AddressPool _addressPool;
  final Dio _dio; // The customized Dio instance (with this interceptor)

  /// 连续连接失败计数。
  ///
  /// **仅用于日志/取证**：它不再参与任何判定 —— 重试阈值由「同地址重试 3 次」
  /// 承担（按请求计，见 [sameAddressRetryCountKey]），切线路阈值由「重试耗尽」
  /// 承担。历史上它是切线路的门槛（`>= 2`），但十几条首屏请求几毫秒内同时
  /// 失败就会把计数瞬间抬过门槛，导致「全部去切线路、一条都不重试」。
  int _consecutiveFailures = 0;

  /// 「多地址切换」重入护栏：切换 + 重放属全链路动作，多条在途请求并发
  /// 失败时只允许一条执行。
  ///
  /// 注意：**同地址重试不受此护栏约束** —— 它有自己按请求隔离的计数和
  /// 全局令牌桶。旧实现把重试也塞进这把全局锁，导致十几条并发请求里只有
  /// 一条能重试，其余直接抛错，这正是「偶发一次抖动 = 整屏空白」的成因之一。
  bool _failoverInFlight = false;

  FallbackInterceptor(this._addressPool, this._dio);

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final active = _addressPool.activeAddress;
    // 活跃地址为空（冷启动 300ms 预算内恢复不出地址 / 旧版本把唯一地址标成了
    // failed）时，绝不能带着空 baseUrl 派发：那样 Uri 没有 host，Dio 会在
    // 适配器之前抛 ArgumentError 并包成 DioExceptionType.unknown —— 既不命中
    // 任何重试分支，也不会触发切线路，首屏十几条并发请求会瞬间全失败，
    // 用户看到的就是「整屏空白 + 网络异常」。
    // 这里退一步用池内最优地址兜底：即使它的 status 是 failed，也比「空 host
    // 必然失败」更接近可用；真实可达性由请求结果与健康探测共同修正。
    final poolAddresses = _addressPool.addresses;
    final effective = active ??
        _addressPool.getNextAvailable() ??
        (poolAddresses.isNotEmpty ? poolAddresses.first : null);
    if (effective != null) {
      // 归一化去尾斜杠：baseUrl 会被封面/流 URL 手工拼接复用，带尾斜杠会
      // 拼出 '//rest/...'（服务端返回 200 + SPA HTML，导致静默全挂）。
      options.baseUrl = normalizeServerBaseUrl(effective.url);
    }
    Logger.debugWithTag(
      _tag,
      'request ${options.method} ${options.path} via '
      '${effective?.label ?? 'no-active-address'}'
      '${active == null && effective != null ? ' (fallback)' : ''}',
    );
    super.onRequest(options, handler);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    if (_consecutiveFailures != 0) {
      Logger.debugWithTag(_tag, 'reset consecutive failure counter');
      _consecutiveFailures = 0;
    }
    // 任一请求成功即取消「待确认的网络异常」：此前只有 HealthChecker 的 30s
    // 周期探测或网络类型变化才会 cancelPending，于是「第 2 秒就自愈了、到
    // t=30s 仍然弹网络异常」。成功响应本身就是最直接的「已恢复」证据。
    NetworkErrorNotifier.cancelPending();
    // 单行响应摘要，替代原来 LogInterceptor 的整版 body 打印。
    Logger.debugWithTag(
      _tag,
      '${response.requestOptions.method} ${response.requestOptions.path} '
      '-> ${response.statusCode}',
    );
    super.onResponse(response, handler);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final options = err.requestOptions;

    // 1) 非连接类错误（4xx/5xx/解析失败…）：不重试、不切换，只清计数。
    if (!_isConnectionError(err)) {
      if (_consecutiveFailures != 0) {
        Logger.debugWithTag(_tag, 'reset consecutive failure counter');
      }
      _consecutiveFailures = 0;
      super.onError(err, handler);
      return;
    }

    // 2) 非幂等请求显式放弃自动重放（重放 POST 可能造成重复写入）。
    if (options.extra[allowRetryExtraKey] == false) {
      Logger.warnWithTag(
        _tag,
        'skip automatic replay for non-idempotent request '
        'path=${options.path}',
        err,
      );
      super.onError(err, handler);
      return;
    }

    _consecutiveFailures++;
    Logger.warnWithTag(
      _tag,
      'connection error, consecutiveFailures=$_consecutiveFailures '
      'path=${options.path} type=${err.type.name}',
      err,
    );

    // 3) receiveTimeout 不重试：请求可能已被服务端处理完（重放有副作用），
    //    而且整个 receiveTimeout 预算（~30s）已经烧掉，再重试只会把首屏拖死。
    if (err.type == DioExceptionType.receiveTimeout) {
      Logger.warnWithTag(
        _tag,
        'receiveTimeout: give up without retry path=${options.path}',
      );
      super.onError(err, handler);
      return;
    }

    // 4) 同地址受限重试 —— 本拦截器的主自愈路径。
    //
    //    这里刻意**没有**「连续失败 >= 2 次才动」的门槛：14 条首屏请求几毫秒
    //    内同时失败会把 _consecutiveFailures 瞬间抬到 2 以上，旧门槛于是让
    //    它们全部跳进「切线路」分支；单地址又切不动，结果一条都不重试、
    //    整屏失败。第一次连接错误就该立刻重试。
    final attempt = _sameAddressRetryCountOf(options);
    // 预算按「有没有别的路可走」分档，而不是固定 3 次：
    //   * 有健康备线且**策略允许切走** → 只给 1 次：请求已发出、对端在给出响应
    //     前断开（半开连接）重发一次即可自愈，但真要切线路时不该先在死路上白等 1s+2s；
    //   * 四种「无备线」情形 → 给满 3 次（这是外网「单一 HTTPS 反代地址」的
    //     主自愈路径，别处无处可去）：
    //       1. 单地址池；
    //       2. 池里还有别的地址，但它已 failed（我们不信它活着，不为它砍自愈）；
    //       3. 备线被锁定（isLocked）；
    //       4. **有备线但被策略禁止切**（手动锁定 + autoFallback 关闭，第 6 步
    //          必然直接抛）—— 这一支根本没有 failover，预算给 1 的唯一理由
    //          （把时间让给切线路）不成立，否则「用户明确锁定的线路」自愈能力
    //          反而低于「单地址裸奔」。
    //
    // 判据刻意用「有没有**健康且未锁定、且不是当前**的地址」而不是「池里几条
    // 地址」：双地址但备线已 failed 时等价于单地址（必须保留 3 次自愈机会），
    // 而单地址池永远等价于「无备线」。
    //
    // 注意这里与第 6 步的判据**故意不对称**，不要「统一」：本处用
    // `status == ok`，而第 6 步实际换线用 getNextAvailable()（内含 `index + 1`
    // 兜底，可能返回一条 failed 地址去 probe）。二者回答的是不同问题 ——
    // 「我有没有一条**信得过**的路」vs「我手上还有没有别的 id 可试」。若把
    // 本处改成「和 getNextAvailable 一致」，就变成「为一条我们其实不信的线路
    // 砍掉自愈次数」。
    //
    // 预算必须钉在**本次逻辑请求的首个失败帧**：切线路之后原线路变 failed，
    // 重新算 hasNextHop 会翻成 false、预算从 1 抬回 3，于是刚切过去的备线又被
    // 重试 3 次 —— 一次故障被放大成 1+3 次。故用 extra 缓存（同一个
    // RequestOptions 会带着它穿过所有递归帧；dio 的 compose 每请求新建 extra，
    // 不会泄漏到别的请求）。
    final budgetValue = options.extra[_retryBudgetExtraKey];
    final int maxAttempts;
    if (budgetValue is int) {
      maxAttempts = budgetValue;
    } else {
      final activeAddress = _addressPool.activeAddress;
      // 有备线 == 「存在另一条 ok 且未锁定的地址」**且**「策略允许切走」。
      // 手动锁定 + 关自动回退时第 6 步必然直接抛（不许切走），此时等同无备线，
      // 应拿满重试预算而不是只打 1 次 —— 否则锁定线路的自愈能力反而低于
      // 单地址裸奔（2 次 vs 4 次），方向是反的。
      final canSwitch =
          !(_addressPool.isManualMode && _addressPool.autoFallback == false);
      final hasNextHop = canSwitch &&
          _addressPool.hasHealthyBackup(excludeId: activeAddress?.id);
      // 注意 `hasHealthyBackup` 里的 `!a.isLocked` 与第 6 步的**不对称**，
      // 这是刻意的、不是 bug：
      //   * 它把 locked 排除在「备线」之外 —— 用户手工锁定的线路不该被当成
      //     自动切换的去处，否则「池里另有一条被锁的线」就会把重试预算无端
      //     砍到 1，而第 6 步其实也切不过去，等于白砍；
      //   * 但第 6 步走的是 getNextAvailable()，它的 index+1 兜底分支
      //     （见 address_pool._getNextAvailable）**不看 isLocked**，所以预算
      //     给满之后第 6 步仍可能真切到一个 locked 地址，且
      //     switchTo(manual: false) 会顺手把它解锁并写回状态。
      // 两处口径不同但结论一致：预算不因「另有一条被锁的线」而缩水，同时
      // 「唯一可用备线被锁」也不会让请求彻底无路可走。
      //
      // 判死（`AddressPool.markFailed`）现在**共用同一个判据**
      // （`hasHealthyBackup`）：否则会出现「重试侧判无备线 → 预算给满」+
      // 「判死侧判有备线 → 把唯一健康地址剔除」的双标。要改这个判据请只改
      // `AddressPool.hasHealthyBackup` 一处。
      maxAttempts = hasNextHop ? 1 : maxSameAddressRetries;
      options.extra[_retryBudgetExtraKey] = maxAttempts;
    }
    if (attempt < maxAttempts) {
      // 5) 令牌桶只约束「延时重试」（attempt >= 1，即 1s / 2s 那两波）。
      //
      //    attempt 0 是**零延时**重发：它只是「换一条新连接、把同一个请求再发
      //    一次」，与首批请求同属一个 burst，最多多一个 RTT，不构成风暴；而它
      //    恰恰是批 A 最想保住的自愈路径 —— 14 条首屏请求同时撞上半开连接
      //    （请求已发出、响应前断开）时，必须人人都有这一次机会。若把 attempt 0 也计费，
      //    14 条里前 4 条吃光 12 枚令牌，其余 10 条一枚都拿不到，「该自愈的
      //    没自愈」，正是本批要修的靶心。
      //    真正要限的是延时波：断网 / 黑洞隧道下 1s、2s 两波会成倍放大请求量。
      var retryAllowed = true;
      // 断网时跳过**延时**重试波，并且**不消耗令牌**（`||` 短路一来就返回，
      // 不会走到 `_tryAcquireRetryToken`）：无路由下 SocketException 是即时
      // 的，1s/2s 两波纯粹白等，还会烧掉 12 枚令牌 —— 挤掉的正是 10s 内
      // 真正需要的那次重试。
      //
      // 只管 `attempt >= 1`：attempt 0 是零延时重发，是批 A 想保住的自愈路径，
      // 也被 Windows 桌面 `connectivity_plus` 的偶发误报保护着（见
      // `AddressPool.isNetworkDown` 的注释）。
      if (attempt >= 1 &&
          (_addressPool.isNetworkDown || !_tryAcquireRetryToken())) {
        if (_addressPool.isNetworkDown) {
          Logger.infoWithTag(
            _tag,
            'network down, skip delayed retry path=${options.path}',
          );
        } else {
          Logger.warnWithTag(
            _tag,
            'retry budget exhausted '
            '($retryTokenLimit/$retryTokenWindow), '
            'fall through to failover path=${options.path}',
          );
        }
        retryAllowed = false;
      }
      if (retryAllowed) {
        final delay = retryBackoff(attempt);
        options.extra[sameAddressRetryCountKey] = attempt + 1;
        if (delay > Duration.zero) {
          Logger.infoWithTag(
            _tag,
            'same-address retry #${attempt + 1} after '
            '${delay.inMilliseconds}ms path=${options.path}',
          );
          await Future<void>.delayed(delay);
        } else {
          Logger.infoWithTag(
            _tag,
            'same-address retry #${attempt + 1} immediately path=${options.path}',
          );
        }
        // 递归安全：`_dio.fetch` 会重新过本拦截器，内层 onError 读到已递增的
        // 计数，最多 3 层后自然落到下面第 6 步 —— 有界递归，不需要 while 包
        // `_dio.get`（那样会丢掉其余拦截器）。鉴权参数是 `u/t/s` 且来源 salt
        // 在会话内固定、无 ts/nonce，重放安全。
        try {
          final response = await _dio.fetch(options);
          Logger.infoWithTag(
            _tag,
            'same-address retry #${attempt + 1} succeeded path=${options.path}',
          );
          _consecutiveFailures = 0;
          // 注意：**除 net_nolock_fallback_test.dart 那条反向验证之外**，删掉
          // 本行其余套件仍然全绿 —— 因为内层 `_dio.fetch` 会重新过拦截器链，
          // 它自己的 onResponse（上面那次 cancelPending）已经覆盖了这条路径。
          // 但这不代表本行冗余：一旦 fetch 的实现不再走拦截器链（dio 升级，
          // 或换成一个自定义 Dio 实现），本行就是这条路径**唯一**的取消来源。
          // 反向验证见 `test/core/network/net_nolock_fallback_test.dart`
          // （不走拦截器链的 Dio 替身，删掉本行该用例即红）。
          //
          // 历史教训：这里早先写过「删掉本行全仓仍全绿、架构性不可拦」——
          // 那只说明当时的套件**覆盖不到**，绝不等于这行可删。
          // `cancelPending` 幂等，多调一次零成本。
          NetworkErrorNotifier.cancelPending();
          handler.resolve(response);
          return;
        } on DioException catch (e) {
          // 内层已判定「继续重试 / 最终放弃 / 已切换」，这里只把结果上抛。
          handler.next(e);
          return;
        } catch (e) {
          // 防御：非 Dio 异常不该从拦截器里裸抛（会掉进 zone 变成未捕获错误）。
          Logger.warnWithTag(
            _tag,
            'same-address retry threw non-Dio error path=${options.path}',
            e,
          );
          handler.next(err);
          return;
        }
      }
    }

    // 6) 同地址重试耗尽 → 多地址故障切换。
    //    单地址时这一步会自然跳过，但**原因不是** getNextAvailable() 返回
    //    null：单地址且 status==ok、未锁定时，它返回的是**该地址自身**
    //    （address_pool._getNextAvailable 的首选分支）。真正拦住重复切换的
    //    是下面 `next.id != currentAddress.id` 那道判断；返回 null 只发生在
    //    该地址已 failed 或 isLocked 时。
    //
    // 手动模式 + 自动回退关闭：重试仍然允许（用户锁的就是这条线），但不切走。
    if (_addressPool.isManualMode && !_addressPool.autoFallback) {
      Logger.warnWithTag(
        _tag,
        'manual mode with autoFallback disabled, skip switch',
      );
      super.onError(err, handler);
      return;
    }

    // 并发重入护栏：一次切换/重放未结束前，其余在途请求直接向上抛，避免
    // 重复切换、切到刚切走的线路、弹多条提示。
    if (_failoverInFlight) {
      Logger.debugWithTag(
        _tag,
        'failover in flight, skip duplicate handling '
        'path=${options.path}',
      );
      super.onError(err, handler);
      return;
    }

    final currentAddress = _addressPool.activeAddress;
    if (currentAddress != null) {
      _failoverInFlight = true;
      try {
        _addressPool.markFailed(currentAddress);

        final next = _addressPool.getNextAvailable();
        if (next != null && next.id != currentAddress.id) {
          Logger.infoWithTag(
            _tag,
            'trying switch: ${currentAddress.label} -> ${next.label}',
          );
          final success = await _addressPool.switchTo(next, manual: false);
          if (success) {
            _consecutiveFailures = 0;
            ToastNotifier.show(
              l10nNowCurrent().core_network_switched_notice(next.label),
            );

            // 用新地址重放一次。重试计数沿用（已到上限），因此新地址上
            // 不再做同地址重试，避免「换线 → 再重试 3 次」把失败时间乘 4。
            options.baseUrl = normalizeServerBaseUrl(next.url);
            try {
              final response = await _dio.fetch(options);
              Logger.infoWithTag(
                _tag,
                'retry succeeded on ${next.label} path=${options.path}',
              );
              handler.resolve(response);
              return;
            } catch (e) {
              Logger.warnWithTag(
                _tag,
                'retry failed on ${next.label} path=${options.path}',
                e,
              );
              if (e is DioException) {
                handler.next(e);
                return;
              }
            }
          } else {
            Logger.warnWithTag(
              _tag,
              'switch rejected by address pool: ${next.label}',
            );
          }
        } else {
          Logger.warnWithTag(
            _tag,
            'no next address available for fallback',
          );
        }
      } finally {
        _failoverInFlight = false;
      }
    }

    super.onError(err, handler);
  }

  /// 取当前逻辑请求在本地址上已重试的次数（缺省 0）。
  int _sameAddressRetryCountOf(RequestOptions options) {
    final value = options.extra[sameAddressRetryCountKey];
    return value is int && value >= 0 ? value : 0;
  }

  /// 从令牌桶取一枚重试令牌；窗口内已用满则返回 false。
  ///
  /// 刻意不用 `Timer`：本类的 static 状态会在 widget 测试的 fake-async
  /// 环境里存活，挂一个周期 Timer 会让「pending timer」直接判测试失败。
  bool _tryAcquireRetryToken() {
    final now = retryClock();
    _retryStamps.removeWhere(
      (stamp) => now.difference(stamp) >= retryTokenWindow,
    );
    if (_retryStamps.length >= retryTokenLimit) return false;
    _retryStamps.add(now);
    return true;
  }

  bool _isConnectionError(DioException err) {
    return err.type == DioExceptionType.connectionTimeout ||
        err.type == DioExceptionType.receiveTimeout ||
        err.type == DioExceptionType.connectionError ||
        (err.type == DioExceptionType.unknown &&
            err.message?.contains('SocketException') == true);
  }
}
