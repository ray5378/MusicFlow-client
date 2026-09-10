// 接续搬移链路结构守卫（CI 防线之一，blocking）。
//
// 钉死 2026-09-10 拍板的「搬移路径必须主通道优先」契约，防止被改回整队推送：
//
//   1) `pushLocalToPeer` 必须**先**尝试主通道 `playContentOnPeer`，仅在
//      内容不可解析（discover/search/other）或主通道失败时才回落整队推送。
//      —— 历史上它只做整队推送，数千首歌单把 MB 级 body 推上公网。
//   2) 起点必须用 `songId`（身份）而非 `startIndex`（本地行号）——
//      两侧排序不同源，用行号会静默播错歌。
//   3) 队列来源必须落盘（会话持久化 `queueOrigin`）并在恢复时回填——
//      否则重启 App 后来源丢失，搬移退化为整队推送，大歌单回归失败。
//   4) 主通道优先的**理由必须留在源码里**（WAF 闸门）——理由被删掉后，
//      后来者很容易把它当成「性能优化」而回退掉，见契约 4。
//
// ============================================================================
// 契约 4 特别说明：为什么这是**可用性**要求而不是性能优化
// ============================================================================
// 公网入口（反代 Lucky WAF）对 `POST /peers/:id/queue/play` + 大批量 JSON
// 数组有**体积闸门**：约 90KB（≈300 首）起即被以 403 拒绝，响应体是
// `<title>403 - Lucky WAF</title>` —— 反代层拒绝，不是 MusicFlow 服务端。
// 即整队推送在公网**不是慢，而是根本发不出去**；主通道 body 恒为几百字节，
// 与队列规模无关，天然不过闸门。
//
// ⚠️ 2026-09-10 真实误判：复测时该闸门**正好被运维临时关闭**，看到
// 541KB/642KB/868KB 均返回 200，于是错误地把上述结论标成「已作废」并改掉了
// 注释，方向完全反了。教训：判定闸门/限流类现象要看**响应体特征**
// （是否含 `Lucky WAF` / 状态码 403），**不能只看体积是否通过**；闸门是可被
// 临时开关的，一次负面复测不足以推翻结论。
// 契约 4 因此额外要求：源码里必须保留闸门说明，防止理由被静默删除。
//
// 为什么用「结构扫描」而不是只靠单测：单测覆盖的是当前实现的行为，
// 而这组契约跨越「播放发起 → 会话落盘 → 重启恢复 → 搬移」四个环节，
// 任何一环被绕开都不会让既有单测变红（已用变异验证确认过：删掉恢复侧回填，
// 全量测试仍全绿）。这里对源码结构做断言，把「绕开」本身变成 CI 失败。
//
// 用法：dart run tool/handoff_chain_scan.dart [lib目录，默认 lib]
// 退出码：0 = 通过；1 = 契约回归（CI 拦截）；2 = 目标文件缺失。
import 'dart:io';

/// 契约 1：搬移入口必须出现主通道调用，且必须出现在兜底整队推送之前。
const String handoffFn = 'pushLocalToPeer';
const String mainChannelCall = 'playContentOnPeer';
const String fallbackCall = '_pushQueueAndPlay';

/// 契约 3：会话 payload 必须携带 / 读取队列来源。
const String sessionOriginKey = 'kSessionQueueOriginKey';
const String sessionOriginReader = 'readSessionQueueOrigin';

/// 契约 4：主通道优先的**理由**（WAF 体积闸门）必须留在源码注释里。
/// 去掉理由后，后人极易把「主通道优先」当成可回退的性能优化。
const String gateRationaleMarker = 'Lucky WAF';

final List<String> failures = <String>[];

void fail(String msg) => failures.add(msg);

/// 取函数体（从签名行的大括号起，按花括号配平截取）。
String? extractFunctionBody(String source, String signature) {
  final start = source.indexOf(signature);
  if (start < 0) return null;
  final braceStart = source.indexOf('{', start);
  if (braceStart < 0) return null;
  var depth = 0;
  for (var i = braceStart; i < source.length; i++) {
    final c = source[i];
    if (c == '{') depth++;
    if (c == '}') {
      depth--;
      if (depth == 0) return source.substring(braceStart, i + 1);
    }
  }
  return null;
}

void checkHandoffMainChannel(File cast) {
  final src = cast.readAsStringSync();
  final body = extractFunctionBody(src, 'Future<bool> $handoffFn(');
  if (body == null) {
    fail('$handoffFn 函数体无法定位（签名被改？）→ 无法验证搬移契约');
    return;
  }

  // 必须是一次**真实的调用**：`playContentOnPeer(` 后面紧跟参数或换行，
  // 且不能是被注释/被改名的形态。用「标识符后紧跟左括号」判定，
  // 避免 `_DISABLED_playContentOnPeer` 或注释里的词蒙混过关。
  final callPattern = RegExp('(?<![A-Za-z0-9_])$mainChannelCall\\s*\\(');
  final mainAt = _firstMatchIndex(body, callPattern);
  final fallbackAt = _firstMatchIndex(
    body,
    RegExp('(?<![A-Za-z0-9_])$fallbackCall\\s*\\('),
  );

  if (mainAt < 0) {
    fail(
      '搬移契约回归：$handoffFn 未真正调用主通道 $mainChannelCall(。\n'
      '    搬移必须主通道优先（只传 contentId+songId，几百字节）；\n'
      '    直接整队推送会把 MB 级 body 推上公网，数千首歌单耗时数秒且易失败。',
    );
    return;
  }
  if (fallbackAt >= 0 && fallbackAt < mainAt) {
    fail(
      '搬移契约回归：$handoffFn 里兜底通道 $fallbackCall 出现在主通道之前。\n'
      '    必须先试主通道、失败才回落。',
    );
  }
  // 起点必须按身份（songId）定位，不能只用本地行号。
  if (!RegExp('songId').hasMatch(body)) {
    fail(
      '搬移契约回归：$handoffFn 未使用 songId 作起点身份。\n'
      '    两侧排序不同源，用本地行号（startIndex）定位会静默播错歌。',
    );
  }
}

/// 返回首个匹配的起始下标（-1 = 无匹配）。
int _firstMatchIndex(String source, RegExp pattern) =>
    pattern.firstMatch(source)?.start ?? -1;

void checkOriginPersisted(File payload, File session) {
  final p = payload.readAsStringSync();
  final s = session.readAsStringSync();

  // 三件事必须同时成立，缺一即链路断（常量定义 ≠ 真的在用）：
  //   (a) 常量有定义；
  //   (b) buildSession 真的把来源写进 payload（`kSessionQueueOriginKey: ` 出现）；
  //   (c) 恢复侧真的用读取入口回填 provider。
  if (!p.contains('const String $sessionOriginKey')) {
    fail(
      '会话契约回归：playback_payload 未定义常量 $sessionOriginKey。',
    );
  }
  if (!RegExp('$sessionOriginKey\\s*:').hasMatch(p)) {
    fail(
      '会话契约回归：buildSession 未把队列来源写入 payload。\n'
      '    只在常量里声明是不够的——必须真的落盘，否则重启后来源丢失。',
    );
  }
  if (!p.contains('Object? $sessionOriginReader(')) {
    fail('会话契约回归：playback_payload 缺少恢复侧读取入口 $sessionOriginReader。');
  }
  if (!s.contains('$sessionOriginReader(session)')) {
    fail(
      '会话契约回归：player_playback_session 恢复时未读取队列来源。',
    );
  }
  if (!RegExp('queueOriginProvider\\.notifier\\)\\.state\\s*=').hasMatch(s)) {
    fail(
      '会话契约回归：player_playback_session 恢复时未向 queueOriginProvider 回填来源。\n'
      '    _restorePlaybackSession 绕过 playEffectiveQueue，必须显式回填，\n'
      '    否则重启 App 后大歌单搬移退化为整队推送。',
    );
  }
}

/// 契约 4：主通道优先的**理由**必须留在 cast_peer_provider 的注释里。
///
/// 只钉行为不钉理由的后果：后人读到「主通道优先」会当成可选优化，
/// 顺手回退成整队推送（尤其在他复测时恰好闸门关闭、看到 200 的情况下）。
/// 把理由留在源码里，是防止这种回退的第一道防线。
void checkGateRationale(File cast) {
  final src = cast.readAsStringSync();
  if (!src.contains(gateRationaleMarker)) {
    fail(
      '契约 4 回归：cast_peer_provider 缺少主通道优先的**理由**说明'
      '（关键字 `$gateRationaleMarker`）。\n'
      '    主通道优先是**可用性要求**，不是性能优化：公网反代对本仓的\n'
      '    POST /queue/play + 大批量 JSON 有 ~90KB 体积闸门，超过即 403，\n'
      '    整队推送在公网根本发不出去。理由被删掉后极易被误判为可回退的优化，\n'
      '    请保留说明（含「闸门可被临时关闭、复测看响应体而非体积」的注意事项）。',
    );
  }
}

void main(List<String> args) {
  final root = args.isNotEmpty ? args.first : 'lib';

  final cast = File('$root/providers/cast/cast_peer_provider.dart');
  final payload = File('$root/core/player/playback_payload.dart');
  final session = File('$root/providers/player/player_playback_session.dart');

  for (final f in <File>[cast, payload, session]) {
    if (!f.existsSync()) {
      stderr.writeln('目标文件不存在: ${f.path}');
      exit(2);
    }
  }

  checkHandoffMainChannel(cast);
  checkOriginPersisted(payload, session);
  checkGateRationale(cast);

  if (failures.isEmpty) {
    stdout.writeln(
      'OK: 接续搬移契约完整（主通道优先 + songId 身份 + 来源持久化 + 闸门理由在案）',
    );
    exit(0);
  }
  stderr.writeln('接续搬移契约检查失败（${failures.length} 项）:');
  for (final f in failures) {
    stderr.writeln('  - $f');
  }
  exit(1);
}
