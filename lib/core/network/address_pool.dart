import 'dart:async';

import 'package:dio/dio.dart';
import 'package:musicflow_client/data/models/server_address.dart';
import 'package:musicflow_client/core/utils/logger.dart';
import 'package:musicflow_client/core/utils/server_url_security.dart';

/// 地址池：管理一个音乐库的多个地址
class AddressPool {
  static const _tag = 'ADDR_POOL';
  final Dio _dio;

  List<ServerAddress> _addresses = [];
  ServerAddress? _activeAddress;
  Future<ServerAddress?>? _probeAllFuture;

  /// 「活跃地址就绪」信号:首次激活地址时 complete(值为该地址),见
  /// [waitForActiveAddress]。已消费过(或地址曾失活)则由等待方按需重建。
  Completer<ServerAddress>? _activeAddressReady;

  /// 把某个地址判定为「不可用」所需的连续健康检查失败次数。
  ///
  /// 加大宽容：偶发的一次超时/抖动不会立刻把明明可用的服务器标记为
  /// [ServerAddressStatus.failed]，从而避免外壳误报「连接不到服务器」。
  static const int requiredConsecutiveFails = 2;

  /// 每个地址当前累计的连续健康检查失败次数（key 为地址 id）。
  final Map<String, int> _consecutiveHealthFails = {};

  /// 自动回退开关：手动选择线路后，线路挂掉是否自动切换到可用线路
  bool autoFallback = true;

  /// 物理网络是否已断开（由 [ConnectivityMonitor] 维护）。
  ///
  /// 唯一用途：让 `FallbackInterceptor` 跳过「延时重试波」（attempt >= 1）。
  /// **attempt 0 的零延时重发不受它影响** —— 那是批 A 最想保住的自愈路径。
  /// 之所以不敢连 attempt 0 一起砍：Windows 桌面 `connectivity_plus` 偶发
  /// 误报 `none`，砍掉 attempt 0 就把误报的代价从「少两次延时重试」放大成
  /// 「完全不自愈」。
  ///
  /// 默认必须是 `false`（不是 nullable）：所有未初始化场景与既有测试都应当
  /// 走批 A 的原始行为，只有 monitor 明确报告 `none` 时才翻转。
  bool isNetworkDown = false;

  // Callback to persist changes (e.g. latency updates)
  final Function(ServerAddress address)? onAddressUpdated;

  // Callback when active address changes
  final Function(ServerAddress? address)? onActiveAddressChanged;

  AddressPool(this._dio, {this.onAddressUpdated, this.onActiveAddressChanged});

  List<ServerAddress> get addresses => List.unmodifiable(_addresses);
  ServerAddress? get activeAddress => _activeAddress;

  /// 事件驱动等待活跃地址就绪(启动首屏请求的前置条件,见
  /// ensureActiveAddressProvider)。
  ///
  /// - 已有活跃地址(setAddresses 恢复成功)→ 同步快路径立即返回,零等待;
  /// - 未就绪(首次启动 / 上次保存态无可恢复地址)→ 挂在内部信号上,
  ///   [_setActiveAddress] 一旦激活地址(恢复或探测选中)即刻唤醒;
  /// - 超过 [timeout] 仍未就绪 → 返回当前值(可能为 null),调用方自行
  ///   走 best-effort 兜底(如 FallbackInterceptor),不再长时间空转。
  Future<ServerAddress?> waitForActiveAddress([
    Duration timeout = const Duration(milliseconds: 300),
  ]) async {
    final active = _activeAddress;
    if (active != null) return active;
    var completer = _activeAddressReady;
    if (completer == null || completer.isCompleted) {
      // 信号已被消费过(或地址曾失活重建):建新信号,等下一次激活。
      completer = Completer<ServerAddress>();
      _activeAddressReady = completer;
    }
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      return _activeAddress;
    }
  }

  /// 当前是否处于手动模式（有锁定的地址）
  bool get isManualMode => _activeAddress?.isLocked == true;

  void setAddresses(List<ServerAddress> newAddresses) {
    Logger.infoWithTag(_tag, 'setAddresses count=${newAddresses.length}');
    _addresses = List.of(newAddresses)
      ..sort((a, b) => a.priority.compareTo(b.priority));

    // If active address is not in new list, reset or pick best
    if (_activeAddress != null &&
        !_addresses.any((a) => a.id == _activeAddress!.id)) {
      Logger.warnWithTag(
        _tag,
        'active address removed from pool: ${_activeAddress!.label}',
      );
      _activeAddress = null;
    }

    // 冷启动加速：不依赖全量探测（慢网/无网时单地址探测可拖到 5s+），
    // 先用上次会话持久化下来的「已知可用」地址立即激活，让首屏请求/封面
    // 第一时间就能用 baseUrl 发起。随后后台 probeAll 校验，若该地址已失效，
    // 探测结果会自动切换到其它可用线路。
    if (_activeAddress == null && _addresses.isNotEmpty) {
      _restoreActiveAddressFromPool();
      probeAll();
    }
  }

  /// 从持久化状态恢复上次可用的活跃地址。
  /// 优先手动锁定地址，其次上次状态为 ok 的最高优先级地址。
  void _restoreActiveAddressFromPool() {
    if (_activeAddress != null || _addresses.isEmpty) return;

    final locked = _addresses.where((a) => a.isLocked).firstOrNull;
    if (locked != null) {
      _setActiveAddress(locked);
      Logger.infoWithTag(
        _tag,
        'restored locked active address: ${locked.label}',
      );
      return;
    }

    // 只认 `ok`。注意 `unknown` 现在有两种含义 ——「初始未探测」和
    // 「suspect（试过但没通过探测，见 switchTo(manual: false)）」—— 两者都
    // 恢复不出来。冷启动时若唯一地址处于 suspect，活跃地址会保持 null，
    // 由 FallbackInterceptor.onRequest 的
    // `active ?? getNextAvailable() ?? addresses.first` 兜底，不会带空 baseUrl。
    final okAddress = _addresses
        .where((a) => a.status == ServerAddressStatus.ok)
        .firstOrNull;
    if (okAddress != null) {
      _setActiveAddress(okAddress);
      Logger.infoWithTag(
        _tag,
        'restored last-known-good active: ${okAddress.label} '
        'lat=${okAddress.lastLatencyMs ?? -1}ms',
      );
    }
  }

  /// 启动时全量探测，选择最优可达地址
  Future<ServerAddress?> probeAll() async {
    final inFlight = _probeAllFuture;
    if (inFlight != null) {
      Logger.debugWithTag(_tag, 'probeAll joined: existing probe in progress');
      return inFlight;
    }

    final future = _probeAllInternal();
    _probeAllFuture = future;
    future.whenComplete(() {
      if (identical(_probeAllFuture, future)) {
        _probeAllFuture = null;
      }
    });
    return future;
  }

  Future<ServerAddress?> _probeAllInternal() async {
    if (_addresses.isEmpty) {
      Logger.warnWithTag(_tag, 'probeAll skipped: empty address list');
      return null;
    }

    Logger.debugWithTag(
      _tag,
      'probeAll start, count=${_addresses.length} '
      'manualMode=$isManualMode autoFallback=$autoFallback '
      'active=${_activeAddress?.label ?? 'none'} '
      'candidates=${_summarizeCandidates()}',
    );

    await Future.wait(
      _addresses.map((addr) async {
        final probed = await probeAddress(addr);
        _applyProbeResult(probed, allowEarlyActiveSelection: true);
      }),
    );

    // 手动模式下只更新延迟数据，不切换活跃地址
    if (isManualMode) {
      // 更新当前活跃地址的探测结果
      final updatedActive = _addresses
          .where((a) => a.id == _activeAddress!.id)
          .firstOrNull;
      if (updatedActive != null) {
        _setActiveAddress(updatedActive);
        Logger.infoWithTag(
          _tag,
          'manual mode keeps active address: ${updatedActive.label}'
          ' status=${updatedActive.status.name}'
          ' latency=${updatedActive.lastLatencyMs ?? -1}ms',
        );
      }
      return _activeAddress;
    }

    // 自动模式：选择最优可达地址
    //
    // 没有可选地址时**保持**原活跃地址，不要置 null：`isOfflineProvider` 的
    // 判据是 `activeAddress.status == failed`，把它清成 null 会让「服务端真的
    // 挂了」漏判成「在线」—— 播放器于是去试在线流并失败（弹「无路由」），
    // 而不是走本地缓存文件。保留一条 failed 的活跃地址，才让离线判定生效。
    final newActive = _getNextAvailable();
    if (newActive != null) _setActiveAddress(newActive);
    if (newActive == null) {
      Logger.warnWithTag(
        _tag,
        'probeAll completed but no available address '
        '(keeping active=${_activeAddress?.label ?? 'none'})',
      );
    }
    return _activeAddress;
  }

  Future<ServerAddress> probeAddress(ServerAddress address) async {
    final start = DateTime.now();
    final uri = Uri.parse(joinServerUrl(address.url, '/rest/ping'));
    final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
    Logger.debugWithTag(
      _tag,
      'probing ${address.label} url=${address.url} '
      'host=${uri.host} port=$port scheme=${uri.scheme} path=${uri.path}',
    );

    try {
      final response = await _dio
          .head(
            uri.toString(),
            options: Options(
              validateStatus: (status) => status != null && status < 500,
              sendTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 10),
            ),
          )
          .timeout(const Duration(seconds: 10));

      final latency = DateTime.now().difference(start).inMilliseconds;
      final contentLength =
          response.headers.value(Headers.contentLengthHeader) ?? '-';
      Logger.debugWithTag(
        _tag,
        'probe response: ${address.label} status=${response.statusCode} '
        'latency=${latency}ms realUri=${response.realUri} '
        'contentLength=$contentLength',
      );
      if (response.statusCode == 200) {
        return address.copyWith(
          status: ServerAddressStatus.ok,
          lastLatencyMs: latency,
        );
      } else {
        Logger.warnWithTag(
          _tag,
          'probe failed (status=${response.statusCode}) for ${address.label}',
        );
        return address.copyWith(
          status: ServerAddressStatus.failed,
          lastLatencyMs: null,
        );
      }
    } catch (e) {
      final latency = DateTime.now().difference(start).inMilliseconds;
      Logger.warnWithTag(
        _tag,
        'probe exception for ${address.label} '
        'latency=${latency}ms url=${uri.toString()}',
        e,
      );
      return address.copyWith(
        status: ServerAddressStatus.failed,
        lastLatencyMs: null,
      );
    }
  }

  String _summarizeCandidates() {
    return _addresses
        .map(
          (address) =>
              '${address.label}@${address.url}'
              '[p=${address.priority},'
              'status=${address.status.name},'
              'locked=${address.isLocked},'
              'lat=${address.lastLatencyMs ?? -1}]',
        )
        .join('; ');
  }

  void _applyProbeResult(
    ServerAddress probed, {
    bool allowEarlyActiveSelection = false,
  }) {
    final index = _addresses.indexWhere((a) => a.id == probed.id);
    if (index == -1) return;

    final current = _addresses[index];
    final probeOk = probed.status == ServerAddressStatus.ok;

    // 「加大宽容」：单次健康检查失败不立刻判为不可用，需连续失败
    // [requiredConsecutiveFails] 次才降级；期间保留上次状态，避免偶发
    // 超时/抖动就把明明可用的服务器误报为连接失败。
    var status = probeOk ? ServerAddressStatus.ok : current.status;
    if (probeOk) {
      _consecutiveHealthFails.remove(probed.id);
    } else {
      final fails = (_consecutiveHealthFails[probed.id] ?? 0) + 1;
      _consecutiveHealthFails[probed.id] = fails;
      if (fails >= requiredConsecutiveFails) {
        status = ServerAddressStatus.failed;
        _consecutiveHealthFails.remove(probed.id);
      } else {
        Logger.debugWithTag(
          _tag,
          'tolerate transient probe failure: ${probed.label} '
          'fail=$fails/$requiredConsecutiveFails '
          'keeping=${current.status.name}',
        );
      }
    }

    final updated = probed.copyWith(isLocked: current.isLocked, status: status);
    _addresses[index] = updated;
    onAddressUpdated?.call(updated);

    if (_activeAddress?.id == updated.id) {
      _setActiveAddress(updated);
    } else if (allowEarlyActiveSelection) {
      _promoteActiveAddressDuringProbe();
    }

    Logger.debugWithTag(
      _tag,
      'updated probe result: ${updated.label}'
      ' status=${updated.status.name}'
      ' latency=${updated.lastLatencyMs ?? -1}ms',
    );
  }

  void _promoteActiveAddressDuringProbe() {
    if (isManualMode) return;

    final current = _activeAddress;
    final hasHealthyActive = current?.status == ServerAddressStatus.ok;
    if (hasHealthyActive) return;

    final next = _getNextAvailable();
    if (next == null) return;
    if (current?.id == next.id &&
        current?.status == next.status &&
        current?.lastLatencyMs == next.lastLatencyMs) {
      return;
    }

    final oldLabel = current?.label ?? 'none';
    _setActiveAddress(next);
    if (current?.id != next.id) {
      Logger.infoWithTag(
        _tag,
        'active address promoted during probe: $oldLabel -> ${next.label}',
      );
    }
  }

  void _setActiveAddress(ServerAddress? newActive) {
    final oldActive = _activeAddress;
    _activeAddress = newActive;

    final changed =
        newActive?.id != oldActive?.id ||
        newActive?.status != oldActive?.status ||
        newActive?.url != oldActive?.url;
    if (!changed) return;

    onActiveAddressChanged?.call(_activeAddress);
    // 唤醒等待「活跃地址就绪」的调用方(见 waitForActiveAddress)。
    final ready = _activeAddressReady;
    if (newActive != null && ready != null && !ready.isCompleted) {
      ready.complete(newActive);
    }
    if (newActive?.id != oldActive?.id) {
      final oldLabel = oldActive?.label ?? 'none';
      final newLabel = newActive?.label ?? 'none';
      Logger.infoWithTag(
        _tag,
        'active address changed: $oldLabel -> $newLabel',
      );
    }
  }

  /// 应用探测结果到内存状态并持久化（保留锁定状态）
  void updateProbedAddress(ServerAddress probed) {
    _applyProbeResult(probed);
  }

  /// 按需探测的节流窗口：失败请求触发的加速探测，全池该窗口内最多 1 次。
  ///
  /// 可变 static 是刻意留给测试推进时钟的口子（设成 [Duration.zero]
  /// 即可绕过窗口），生产代码不要改它。
  static Duration onDemandProbeInterval = const Duration(seconds: 5);

  DateTime _lastOnDemandProbeAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _onDemandProbeInFlight = false;

  /// 「失败请求」触发的**限速**探测，用来把判死延迟从 30~70s 压到 ~10s。
  ///
  /// **绝不能在失败路径上直接 `probeAll()`**：首屏十几条请求同时失败就是
  /// 十几次全量探测（双地址 = 2×N 个 HEAD），那是拿一个新的风暴去换旧的。
  /// 这里三重限速：
  ///   1. 只探**一条**（活跃地址；没有就取最佳候选），不全量；
  ///   2. 全池 [_lastOnDemandProbeAt] 窗口内最多 1 次；
  ///   3. 上一次点探测还没结束就直接返回（[_onDemandProbeInFlight]）。
  ///
  /// 结果走 [_applyProbeResult] 的**宽容路径**（连续
  /// [requiredConsecutiveFails] 次才降级为 failed）—— 这是关键：一次失败
  /// 请求只把状态推向 suspect，不会直接把线路打死。
  ///
  /// 刻意用 `DateTime` 而不是 `Timer`：static/长生命周期 Timer 会让 widget
  /// 测试的 pending-timer 判定失败（同令牌桶当初的理由）。
  Future<void> probeActiveThrottled() async {
    if (_onDemandProbeInFlight) return;
    final target = _activeAddress ??
        _getNextAvailable() ??
        (_addresses.isNotEmpty ? _addresses.first : null);
    if (target == null) return;
    final now = DateTime.now();
    if (now.difference(_lastOnDemandProbeAt) < onDemandProbeInterval) return;
    _lastOnDemandProbeAt = now;
    _onDemandProbeInFlight = true;
    try {
      final probed = await probeAddress(target);
      _applyProbeResult(probed);
    } catch (e) {
      // 探测自身已把异常吞成 failed；这里兜住「归类之外」的错误，避免从
      // 后台路径裸抛进 zone 变成未捕获异常。
      Logger.warnWithTag(
        _tag,
        'on-demand probe threw for ${target.label}',
        e,
      );
    } finally {
      _onDemandProbeInFlight = false;
    }
  }

  /// 是否存在一条「健康、未锁定、且不是 [excludeId]」的地址 —— 即自动切线路
  /// 真正可信的去处。
  ///
  /// **这是「有没有备线」的唯一判据**：重试预算（`FallbackInterceptor.onError`
  /// 的第 4 步）与判死（[markFailed]）共用它，避免「1 ok + 1 failed」时
  /// 重试侧判无备线、判死侧判有备线的双标 —— 那种双标会让重试把时间让给一次
  /// 注定失败的 failover，同时又把唯一健康的地址从候选里剔除。
  ///
  /// 刻意走**公开的 [addresses]** 而不是内部 `_addresses`：`addresses` 是
  /// 可覆写的 getter，测试替身（如 `_FixedPool`）只覆写得到它；用私有字段会
  /// 让「预算分档 / 判死」这两条判据在替身上恒为 false，等于把判据变成不可测。
  /// 二者内容一致（[addresses] 就是 `_addresses` 的只读视图）。
  bool hasHealthyBackup({String? excludeId}) => addresses.any(
        (a) =>
            a.id != excludeId &&
            !a.isLocked &&
            a.status == ServerAddressStatus.ok,
      );

  /// 标记某地址「本次请求失败」。
  ///
  /// **没有可信备线时刻意跳过判死，这不是遗漏**：
  ///
  /// 判死的**唯一用途**是给切换让路 —— 唯一调用点在
  /// `fallback_interceptor.dart` 的第 6 步，紧接着就调 [getNextAvailable]
  /// 挑下一跳。所以没有备线时判死不但无用，而且有毒：
  ///   1. 它会把「唯一的健康地址」从 [getNextAvailable] 的候选里剔除，
  ///      逼第 6 步走 `_getNextAvailable` 的 `index + 1` 兜底分支（那条**不看
  ///      status**），去 probe 一条我们本来就不信的地址；
  ///   2. 状态经 [onAddressUpdated] 被持久化成 `failed`，下次冷启动
  ///      [_restoreActiveAddressFromPool] 只认 `status == ok`，恢复不出活跃
  ///      地址，首屏请求便带着空 baseUrl 派发（Uri 无 host → ArgumentError →
  ///      不命中任何重试分支），整屏空白 + 报网络异常；
  ///   3. `isOfflineProvider` 把 `activeAddress.status == failed` 直接当成
  ///      离线，于是封面全占位、播放被拒、遥控不可达。
  ///
  /// 外网是「单一 HTTPS 反代地址」，根本没有备线可切，判死等于自我否决。
  /// 真实可达性交给 HealthChecker 的周期探测（连续 [requiredConsecutiveFails]
  /// 次失败才降级，见 [_applyProbeResult]），请求路径这里不参与判死。
  void markFailed(ServerAddress addr) {
    if (!hasHealthyBackup(excludeId: addr.id)) {
      Logger.warnWithTag(
        _tag,
        'markFailed skipped when no healthy backup (deliberate design): '
        '${addr.label}',
      );
      return;
    }
    final index = _addresses.indexWhere((a) => a.id == addr.id);
    if (index != -1) {
      Logger.warnWithTag(_tag, 'markFailed: ${addr.label}');
      _addresses[index] = _addresses[index].copyWith(
        status: ServerAddressStatus.failed,
      );
      onAddressUpdated?.call(_addresses[index]);
      if (_activeAddress?.id == addr.id) {
        _activeAddress = _addresses[index];
        onActiveAddressChanged?.call(_activeAddress);
      }
    }
  }

  /// 获取下一个可用地址（按优先级）
  ServerAddress? getNextAvailable() {
    return _getNextAvailable();
  }

  ServerAddress? _getNextAvailable() {
    // Find first OK address
    final okAddress = _addresses
        .where((a) => a.status == ServerAddressStatus.ok && !a.isLocked)
        .firstOrNull;
    if (okAddress != null) return okAddress;

    // No OK address found — try next in list after current active
    if (_activeAddress != null) {
      final currentIndex = _addresses.indexWhere(
        (a) => a.id == _activeAddress!.id,
      );
      if (currentIndex != -1 && currentIndex < _addresses.length - 1) {
        return _addresses[currentIndex + 1];
      }
    } else if (_addresses.isNotEmpty) {
      return _addresses.first;
    }
    return null;
  }

  /// 切换到自动模式（解锁所有地址，自动选择最优）
  Future<void> setAutoMode() async {
    Logger.infoWithTag(_tag, 'switching to auto mode');
    for (int i = 0; i < _addresses.length; i++) {
      if (_addresses[i].isLocked) {
        _addresses[i] = _addresses[i].copyWith(isLocked: false);
        onAddressUpdated?.call(_addresses[i]);
      }
    }
    await probeAll();
  }

  /// 切换到手动模式（锁定指定地址）
  Future<void> setManualMode(ServerAddress addr) async {
    Logger.infoWithTag(_tag, 'switching to manual mode: ${addr.label}');
    // Probe it first to update latency
    final probed = await probeAddress(addr);

    // Update in list and lock it
    for (int i = 0; i < _addresses.length; i++) {
      var a = _addresses[i];
      if (a.id == addr.id) {
        // Update with probed data AND lock it
        _addresses[i] = probed.copyWith(isLocked: true);
        onAddressUpdated?.call(_addresses[i]);
        _activeAddress = _addresses[i];
        onActiveAddressChanged?.call(_activeAddress);
        Logger.infoWithTag(
          _tag,
          'manual active address set: ${_activeAddress?.label ?? addr.label}',
        );
      } else if (a.isLocked) {
        // Unlock others
        _addresses[i] = a.copyWith(isLocked: false);
        onAddressUpdated?.call(_addresses[i]);
      }
    }
  }

  /// 切换到指定地址 (Deprecated: use setManualMode)
  Future<bool> switchTo(ServerAddress addr, {bool manual = true}) async {
    Logger.infoWithTag(
      _tag,
      'switchTo requested: ${addr.label}, manual=$manual',
    );
    if (manual) {
      await setManualMode(addr);
      final ok = _activeAddress?.status == ServerAddressStatus.ok;
      Logger.infoWithTag(_tag, 'switchTo(manual) result=$ok');
      return ok;
    }

    final probed = await probeAddress(addr);
    final probedOk = probed.status == ServerAddressStatus.ok;
    final oldActiveId = _activeAddress?.id;
    ServerAddress? newActive;

    for (int i = 0; i < _addresses.length; i++) {
      final current = _addresses[i];
      if (current.id == addr.id) {
        _addresses[i] = probed.copyWith(
          isLocked: false,
          // 候选探测失败只降级为 suspect（复用已有的 `unknown`），**不写
          // failed**：`failed` 会让 `isOfflineProvider` 判全 App 离线（封面
          // 全占位 + 播放被跳过 + 暂停下载，见其 5 个消费点），而单次探测失败
          // 远不足以证明它长期不可用。真正的 `failed` 只由
          // [_applyProbeResult] 在连续 [requiredConsecutiveFails] 次失败后给出。
          //
          // 注意 `unknown` 从此多了一层语义 =「suspect（试过但没通过）」，
          // 不再只是「初始未探测」。[_restoreActiveAddressFromPool] 只认
          // `ok`，所以 suspect 地址冷启动时恢复不出来 —— 由
          // FallbackInterceptor.onRequest 的
          // `active ?? getNextAvailable() ?? first` 兜底，不会空 baseUrl。
          status: probedOk
              ? ServerAddressStatus.ok
              : ServerAddressStatus.unknown,
        );
        onAddressUpdated?.call(_addresses[i]);
        newActive = _addresses[i];
      } else if (current.isLocked) {
        _addresses[i] = current.copyWith(isLocked: false);
        onAddressUpdated?.call(_addresses[i]);
      }
    }

    // 只有探测通过才真正切过去。探测失败时保持原活跃地址不动 —— 旧实现会把
    // 活跃地址直接设成这条没通过探测的候选，于是 `isOfflineProvider` 立刻为
    // true，用户看到的是封面全占位 + 播放被跳过，比「没切成功」糟得多。
    if (probedOk && newActive != null) {
      _activeAddress = newActive;
      if (_activeAddress?.id != oldActiveId) {
        onActiveAddressChanged?.call(_activeAddress);
      }
    }

    // 返回值语义 =「这条候选探测通过了吗」，**不能**改成读 `_activeAddress`
    // 的状态：探测失败时活跃地址仍是那条 ok 的旧地址，读它会返回 true，让
    // 第 6 步误以为已经切好并去重放请求（打在原地）。
    Logger.infoWithTag(
      _tag,
      'switchTo(auto) result=$probedOk probeOk=$probedOk '
      'active=${_activeAddress?.label ?? 'none'}',
    );
    return probedOk;
  }

  /// 用户手动锁定某地址（不参与自动切换）
  void lockAddress(ServerAddress addr) {
    setManualMode(addr);
  }
}
