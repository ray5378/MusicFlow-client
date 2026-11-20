import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:musicflow_client/providers/api/api_provider.dart';

/// 服务端「维护」能力探测（2026-11-20）。
///
/// 判据完全交给服务端：`GET /rest/api/v1/system/restart` 挂了 adminMiddleware，
/// 管理员 200、非管理员 403。客户端据此决定设置页是否渲染「维护」模块 ——
/// 不在客户端另外维护一份"谁算管理员"的逻辑（两份判据必然漂移）。
final serverRestartCapabilityProvider = FutureProvider<bool>((ref) async {
  final client = ref.watch(subsonicApiClientProvider);
  try {
    final raw = await client.getRaw(
      '/rest/api/v1/system/restart',
      receiveTimeout: const Duration(seconds: 6),
    );
    return raw is Map && raw['allowed'] == true;
  } catch (_) {
    // 403（非管理员）、离线、服务正在重启 —— 一律按"当前不可管理"处理，
    // 模块不渲染。真正的权限判定在服务端，这里只是可见性。
    return false;
  }
});

enum ServerRestartStage { idle, running, done, failed }

class ServerRestartState {
  const ServerRestartState(this.stage);

  final ServerRestartStage stage;

  bool get isRunning => stage == ServerRestartStage.running;
}

/// 服务端自我重启（维护）。
///
/// 时间线（240 实测）：POST 202 → 进程约 1.3s 后退出 → 容器 restart=always 拉起
/// → 2.2s 恢复监听 → 10s 内自动续播刚才那首。所以这里最多等 60s，期间连接失败
/// 都是"正在重启"的正常表现，不是错误。
class ServerRestartController extends StateNotifier<ServerRestartState> {
  ServerRestartController(this._ref)
    : super(const ServerRestartState(ServerRestartStage.idle));

  final Ref _ref;

  Future<bool> restart({Duration timeout = const Duration(seconds: 60)}) async {
    if (state.isRunning) return false;
    state = const ServerRestartState(ServerRestartStage.running);

    try {
      await _ref
          .read(subsonicApiClientProvider)
          .postRaw('/rest/api/v1/system/restart', data: const <String, dynamic>{});
    } catch (_) {
      // 进程可能在响应写回之前就退出（连接被掐断），这同样是"重启已开始"。
      // 继续走下面的等待恢复，不把它当失败。
    }

    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(seconds: 1));
      try {
        final raw = await _ref
            .read(subsonicApiClientProvider)
            .getRaw(
              '/rest/api/v1/system/restart',
              receiveTimeout: const Duration(seconds: 3),
            );
        if (raw is Map && raw['allowed'] == true) {
          state = const ServerRestartState(ServerRestartStage.done);
          return true;
        }
      } catch (_) {
        // 重启窗口内：连接拒绝/超时/502 都正常，继续等。
      }
    }

    state = const ServerRestartState(ServerRestartStage.failed);
    return false;
  }
}

final serverRestartControllerProvider =
    StateNotifierProvider<ServerRestartController, ServerRestartState>((ref) {
      return ServerRestartController(ref);
    });
